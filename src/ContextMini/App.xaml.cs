using System.Windows;
using ContextMini.Core;

namespace ContextMini;

public partial class App : Application
{
    private AppearanceManager? _appearance;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _appearance = new AppearanceManager(this, AppearanceSettingsStore.CreateDefault());
        var initialProject = e.Args.Length > 0 ? e.Args[0] : Environment.CurrentDirectory;
        var window = new MainWindow(initialProject, _appearance);
        MainWindow = window;
        window.Show();
    }
}
