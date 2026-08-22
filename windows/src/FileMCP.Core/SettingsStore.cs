using System.Text.Json;

namespace FileMCP.Core;

public sealed class SettingsStore
{
    private readonly string _path;
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    public SettingsStore(string? directory = null)
    {
        var root = directory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FileMCP");
        _path = Path.Combine(root, "settings.json");
    }

    public FileMcpSettings Load()
    {
        if (!File.Exists(_path)) return new FileMcpSettings();
        try
        {
            var settings = JsonSerializer.Deserialize<FileMcpSettings>(File.ReadAllText(_path), JsonOptions) ?? new FileMcpSettings();
            if (settings.Port is < 1 or > 65535) settings.Port = 8008;
            if (string.IsNullOrWhiteSpace(settings.Profile)) settings.Profile = "filemcp";
            if (string.IsNullOrWhiteSpace(settings.AllowedDirectory)) settings.AllowedDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "FileMCP");
            if (string.IsNullOrWhiteSpace(settings.HealthAddress)) settings.HealthAddress = "127.0.0.1:0";
            return settings;
        }
        catch (JsonException ex) { throw new FileMcpException("Could not read FileMCP settings: " + ex.Message); }
    }

    public void Save(FileMcpSettings settings)
    {
        var directory = Path.GetDirectoryName(_path)!; Directory.CreateDirectory(directory);
        var temp = _path + ".tmp-" + Guid.NewGuid().ToString("N");
        try { File.WriteAllText(temp, JsonSerializer.Serialize(settings, JsonOptions)); File.Move(temp, _path, true); }
        finally { try { if (File.Exists(temp)) File.Delete(temp); } catch { } }
    }
}
