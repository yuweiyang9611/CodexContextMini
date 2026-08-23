using System.Windows;

namespace ContextMini;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var initialProject = e.Args.Length > 0 ? e.Args[0] : Environment.CurrentDirectory;
        var window = new MainWindow(initialProject);
        MainWindow = window;
        window.Show();
    }
}
