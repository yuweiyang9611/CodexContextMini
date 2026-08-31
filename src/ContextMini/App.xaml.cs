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
        var initialProject = ResolveInitialProject(e.Args, recentProjects);
        var window = new MainWindow(initialProject, _appearance, recentProjects);
        MainWindow = window;
        window.Show();
    }

    internal static string ResolveInitialProject(string[] arguments, RecentProjectsStore recentProjects)
    {
        if (arguments.Length > 0) return arguments[0];
        try
        {
            return recentProjects.Load().FirstOrDefault() ?? string.Empty;
        }
        catch (Exception exception)
        {
            System.Diagnostics.Debug.WriteLine($"Could not restore the most recent project: {exception}");
            return string.Empty;
        }
    }
}
