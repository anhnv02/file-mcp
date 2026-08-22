using System.Windows;

namespace FileMCP.App;

public partial class App : System.Windows.Application
{
    private MainWindow? _window;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _window = new MainWindow();
        MainWindow = _window;
        SessionEnding += (_, _) => _window.ShutdownForSystemSession();
        _window.Show();
    }
}
