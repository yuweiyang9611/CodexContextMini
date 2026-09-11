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
        var recentProjects = RecentProjectsStore.CreateDefault();
        var initialProject = ResolveInitialProject(e.Args);
        var window = new MainWindow(initialProject, _appearance, recentProjects);
        MainWindow = window;
        window.Show();
    }

    internal static string ResolveInitialProject(string[] arguments)
    {
        // No project argument means user-wide defaults, regardless of recent projects.
        return arguments.Length > 0 && arguments[0] != "--global" ? arguments[0] : string.Empty;
    }
}
