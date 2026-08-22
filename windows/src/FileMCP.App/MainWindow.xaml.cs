using System.ComponentModel;
using System.Drawing;
using System.IO;
using System.Windows;
using System.Windows.Input;
using FileMCP.Core;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace FileMCP.App;

public partial class MainWindow : Window
{
    private readonly SettingsStore _settingsStore = new();
    private readonly WindowsCredentialStore _credentialStore = new();
    private readonly LocalMcpRuntime _runtime = new();
    private readonly Forms.NotifyIcon _trayIcon;
    private FileMcpSettings _settings;
    private bool _quitting;
    private string _logBuffer = "";
    private const int MaxLogCharacters = 500_000;

    public MainWindow()
    {
        InitializeComponent();
        _settings = LoadSettingsSafely();
        ApplySettings(_settings);
        UpdateApiKeyStatus();

        _runtime.Log += text => Dispatcher.BeginInvoke(new Action(() => AppendLog(text)));
        _runtime.StateChanged += state => Dispatcher.BeginInvoke(new Action(() => UpdateRuntimeState(state)));
        Closing += OnClosing;
        PreviewKeyDown += OnPreviewKeyDown;

        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open FileMCP", null, (_, _) => Dispatcher.Invoke(ShowFromTray));
        menu.Items.Add("About FileMCP", null, (_, _) => Dispatcher.Invoke(ShowAbout));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit FileMCP", null, (_, _) => Dispatcher.Invoke(async () => await QuitAsync()));
        _trayIcon = new Forms.NotifyIcon
        {
            Text = "FileMCP",
            Visible = true,
            ContextMenuStrip = menu,
            Icon = LoadApplicationIcon(),
        };
        _trayIcon.DoubleClick += (_, _) => Dispatcher.Invoke(ShowFromTray);
        UpdateRuntimeState(_runtime.State);
    }

    private FileMcpSettings LoadSettingsSafely()
    {
        try { return _settingsStore.Load(); }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(this, ex.Message, "FileMCP", MessageBoxButton.OK, MessageBoxImage.Warning);
            return new FileMcpSettings();
        }
    }

    private void ApplySettings(FileMcpSettings settings)
    {
        TunnelIdBox.Text = settings.TunnelId;
        ProfileBox.Text = settings.Profile;
        PortBox.Text = settings.Port.ToString();
        DirectoryBox.Text = settings.AllowedDirectory;
        HealthAddressBox.Text = settings.HealthAddress;
        GitNameBox.Text = settings.GitUserName;
        GitEmailBox.Text = settings.GitUserEmail;
        EnableCommandsCheckBox.IsChecked = settings.EnableCommands;
    }

    private void UpdateApiKeyStatus()
    {
        var saved = _credentialStore.HasSavedApiKey;
        ApiKeyStatusText.Text = saved ? "API key is saved in Windows Credential Manager" : "No API key is saved";
        DeleteApiKeyButton.IsEnabled = saved;
    }

    private async void Connect_Click(object sender, RoutedEventArgs e)
    {
        var status = _runtime.State.Status;
        if (status is LocalMcpRuntimeStatus.Running or LocalMcpRuntimeStatus.Starting)
        {
            await _runtime.StopAsync();
            return;
        }
        if (status == LocalMcpRuntimeStatus.Stopping) return;
        if (!ValidateConnection(requireApiKey: true) || !ValidateSettings()) return;

        try
        {
            var typedKey = ApiKeyBox.Password.Trim();
            if (typedKey.Length > 0)
            {
                _credentialStore.SaveApiKey(typedKey);
                ApiKeyBox.Password = "";
                UpdateApiKeyStatus();
            }
            var apiKey = _credentialStore.ReadApiKey();
            SaveAllSettings();
            var configuration = new LocalMcpConfiguration(
                TunnelIdBox.Text.Trim(), apiKey, ProfileBox.Text.Trim(), checked((ushort)_settings.Port),
                DirectoryBox.Text.Trim(), HealthAddressBox.Text.Trim(), GitNameBox.Text.Trim(), GitEmailBox.Text.Trim(),
                EnableCommandsCheckBox.IsChecked == true);
            await _runtime.StartAsync(configuration);
        }
        catch (Exception ex) { ShowError(ex.Message); }
    }

    private void SaveConnection_Click(object sender, RoutedEventArgs e)
    {
        if (!ValidateConnection(requireApiKey: true)) return;
        try
        {
            var typedKey = ApiKeyBox.Password.Trim();
            if (typedKey.Length > 0)
            {
                _credentialStore.SaveApiKey(typedKey);
                ApiKeyBox.Password = "";
            }
            _settings.TunnelId = TunnelIdBox.Text.Trim();
            _settingsStore.Save(_settings);
            UpdateApiKeyStatus();
            AppendLog("Connection settings saved.\n");
            if (_runtime.State.Status != LocalMcpRuntimeStatus.Stopped) AppendLog("Changes will take effect the next time the tunnel starts.\n");
        }
        catch (Exception ex) { ShowError(ex.Message); }
    }

    private void SaveSettings_Click(object sender, RoutedEventArgs e)
    {
        if (!ValidateSettings()) return;
        try
        {
            SaveSettingsFields();
            _settingsStore.Save(_settings);
            AppendLog("Settings saved.\n");
            if (_runtime.State.Status != LocalMcpRuntimeStatus.Stopped) AppendLog("Changes will take effect the next time the tunnel starts.\n");
        }
        catch (Exception ex) { ShowError(ex.Message); }
    }

    private void DeleteApiKey_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            _credentialStore.DeleteApiKey();
            ApiKeyBox.Password = "";
            UpdateApiKeyStatus();
        }
        catch (Exception ex) { ShowError(ex.Message); }
    }

    private void BrowseDirectory_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog
        {
            Title = "Choose shared directory",
            Multiselect = false,
            InitialDirectory = Directory.Exists(DirectoryBox.Text) ? DirectoryBox.Text : Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
        };
        if (dialog.ShowDialog(this) == true) DirectoryBox.Text = dialog.FolderName;
    }

    private async void Quit_Click(object sender, RoutedEventArgs e) => await QuitAsync();

    private bool ValidateConnection(bool requireApiKey)
    {
        var tunnelId = TunnelIdBox.Text.Trim();
        if (tunnelId.Length == 0) { MainTabs.SelectedItem = ConnectionTab; ShowError("Enter a Tunnel ID in the Connection tab."); return false; }
        if (!LocalMcpRuntime.IsValidTunnelId(tunnelId)) { MainTabs.SelectedItem = ConnectionTab; ShowError("Tunnel ID must match tunnel_<32 lowercase letters or digits>."); return false; }
        if (requireApiKey && ApiKeyBox.Password.Trim().Length == 0 && !_credentialStore.HasSavedApiKey) { MainTabs.SelectedItem = ConnectionTab; ShowError("Enter a Runtime API key in the Connection tab."); return false; }
        return true;
    }

    private bool ValidateSettings()
    {
        if (DirectoryBox.Text.Trim().Length == 0) { MainTabs.SelectedItem = SettingsTab; ShowError("Choose a shared directory."); return false; }
        if (!LocalMcpRuntime.IsValidProfileName(ProfileBox.Text.Trim())) { MainTabs.SelectedItem = SettingsTab; AdvancedExpander.IsExpanded = true; ShowError("Profile must start with a letter or number and contain only letters, numbers, '.', '_' or '-' (maximum 128 characters)."); return false; }
        if (!int.TryParse(PortBox.Text.Trim(), out var port) || port is < 1 or > 65535) { MainTabs.SelectedItem = SettingsTab; AdvancedExpander.IsExpanded = true; ShowError("MCP port must be between 1 and 65535."); return false; }
        if (LocalMcpRuntime.NormalizeHealthAddress(HealthAddressBox.Text.Trim()) is null) { MainTabs.SelectedItem = SettingsTab; AdvancedExpander.IsExpanded = true; ShowError("Health listener must use localhost, 127.0.0.1, or [::1] with a port from 0 to 65535."); return false; }
        return true;
    }

    private void SaveAllSettings()
    {
        _settings.TunnelId = TunnelIdBox.Text.Trim();
        SaveSettingsFields();
        _settingsStore.Save(_settings);
    }

    private void SaveSettingsFields()
    {
        _settings.Profile = ProfileBox.Text.Trim();
        _settings.Port = int.Parse(PortBox.Text.Trim());
        _settings.AllowedDirectory = DirectoryBox.Text.Trim();
        _settings.HealthAddress = HealthAddressBox.Text.Trim();
        _settings.GitUserName = GitNameBox.Text.Trim();
        _settings.GitUserEmail = GitEmailBox.Text.Trim();
        _settings.EnableCommands = EnableCommandsCheckBox.IsChecked == true;
    }

    private void UpdateRuntimeState(LocalMcpRuntimeState state)
    {
        switch (state.Status)
        {
            case LocalMcpRuntimeStatus.Stopped:
            case LocalMcpRuntimeStatus.Failed:
                ConnectButton.Content = "Connect"; ConnectButton.IsEnabled = true; break;
            case LocalMcpRuntimeStatus.Starting:
                ConnectButton.Content = "Connecting…"; ConnectButton.IsEnabled = false; break;
            case LocalMcpRuntimeStatus.Running:
                ConnectButton.Content = "Disconnect"; ConnectButton.IsEnabled = true; break;
            case LocalMcpRuntimeStatus.Stopping:
                ConnectButton.Content = "Disconnecting…"; ConnectButton.IsEnabled = false; break;
        }
        if (state.Status == LocalMcpRuntimeStatus.Failed && !string.IsNullOrEmpty(state.Error)) ShowError(state.Error);
    }

    private void AppendLog(string text)
    {
        _logBuffer += text;
        if (_logBuffer.Length > MaxLogCharacters)
            _logBuffer = "[...older log truncated...]\n" + _logBuffer[^MaxLogCharacters..];
        LogBox.Text = _logBuffer;
        LogBox.ScrollToEnd();
    }

    private void ShowError(string message) => System.Windows.MessageBox.Show(this, message, "FileMCP", MessageBoxButton.OK, MessageBoxImage.Warning);

    private void ShowAbout()
    {
        System.Windows.MessageBox.Show(
            this,
            "FileMCP 0.4.0\n\nNative Windows MCP bridge for controlled local file, Git, and optional command access.",
            "About FileMCP",
            MessageBoxButton.OK,
            MessageBoxImage.Information);
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_quitting) return;
        e.Cancel = true;
        Hide();
    }

    private void ShowFromTray()
    {
        Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        Topmost = true; Topmost = false;
    }

    public void ShutdownForSystemSession()
    {
        if (_quitting) return;
        _quitting = true;
        try { _runtime.ShutdownAsync().GetAwaiter().GetResult(); } catch { }
        _trayIcon.Visible = false;
        _trayIcon.Dispose();
    }

    private async Task QuitAsync()
    {
        if (_quitting) return;
        _quitting = true;
        try { await _runtime.ShutdownAsync(); }
        finally
        {
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
            await _runtime.DisposeAsync();
            System.Windows.Application.Current.Shutdown();
        }
    }

    private void OnPreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if ((Keyboard.Modifiers & ModifierKeys.Control) == 0) return;
        if (e.Key == Key.W) { Hide(); e.Handled = true; }
        else if (e.Key == Key.OemComma) { MainTabs.SelectedItem = SettingsTab; ShowFromTray(); e.Handled = true; }
        else if (e.Key == Key.Q) { _ = QuitAsync(); e.Handled = true; }
    }

    private static System.Drawing.Icon LoadApplicationIcon()
    {
        var icon = Environment.ProcessPath is { Length: > 0 } path ? System.Drawing.Icon.ExtractAssociatedIcon(path) : null;
        return icon ?? SystemIcons.Application;
    }
}
