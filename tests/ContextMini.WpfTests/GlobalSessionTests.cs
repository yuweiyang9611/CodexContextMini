using System.IO;
using System.Windows;
using ContextMini.Core;

namespace ContextMini.WpfTests;

internal static partial class Program
{
    private static void RunGlobalSessionTests()
    {
        Run("global session monitor, reload and rebase retain the target", GlobalSessionReload);
        Run("scope switches reject late results and old apply previews", GlobalSessionSwitch);
        Run("global scope is displayed with its exact configuration path", GlobalScopePresentation);
    }

    private static ConfigSnapshot GlobalSnapshot(string fingerprint) =>
        Snapshot(@"C:\isolated-codex-home", fingerprint, 400_000, 320_000) with
        {
            ConfigurationScope = ConfigurationScope.Global,
            ConfigPath = @"C:\isolated-codex-home\config.toml",
        };

    private static void GlobalSessionReload()
    {
        var store = new ControlledProjectSessionStore();
        var session = new ProjectSessionController(store);
        var baseline = GlobalSnapshot("baseline");
        store.EnqueueLoadResult(baseline);
        True(session.LoadTargetAsync(baseline.Target, false).GetAwaiter().GetResult().Succeeded);
        True(session.TrySetDraft(ContextPolicy.OneMillion));
        var latest = GlobalSnapshot("external");
        store.EnqueueLoadResult(latest);
        Equal(SessionMonitorKind.Conflict, session.MonitorAsync().GetAwaiter().GetResult().Kind);
        Equal(baseline.Target, store.LastLoadTarget);
        True(session.TryRebasePending());
        Equal(ContextPolicy.OneMillion, session.Draft);
        Equal(ConfigurationScope.Global, session.Snapshot!.ConfigurationScope);
        store.EnqueueLoadResult(latest);
        True(session.LoadTargetAsync(session.Snapshot.Target, true).GetAwaiter().GetResult().Succeeded);
        Equal(baseline.Target, store.LastLoadTarget);
        True(session.CanApply);
    }

    private static void GlobalSessionSwitch()
    {
        var store = new ControlledProjectSessionStore();
        var session = new ProjectSessionController(store);
        var global = GlobalSnapshot("global");
        store.EnqueueLoadResult(global);
        True(session.LoadTargetAsync(global.Target, false).GetAwaiter().GetResult().Succeeded);
        True(session.TrySetDraft(ContextPolicy.OneMillion));
        var ticket = session.TryCreateApplyTicket()!;
        var pending = store.EnqueuePendingLoad();
        var monitor = session.MonitorAsync();
        // The same root with a different scope still denotes a different config file.
        var project = Snapshot(global.ProjectRoot, "project", 128_000, 96_000);
        store.EnqueueLoadResult(project);
        True(session.LoadProjectAsync(project.ProjectRoot, false).GetAwaiter().GetResult().Succeeded);
        pending.SetResult(global);
        Equal(SessionMonitorKind.Superseded, monitor.GetAwaiter().GetResult().Kind);
        Equal(ConfigurationScope.Project, session.Snapshot!.ConfigurationScope);
        True(session.TrySetDraft(ContextPolicy.OneMillion));
        Equal(SessionApplyKind.StalePreview, session.ApplyAsync(ticket).GetAwaiter().GetResult().Kind);
        Equal(0, store.ApplyCallCount);
    }

    private static void GlobalScopePresentation()
    {
        WithDirectory(root =>
        {
            var manager = new AppearanceManager(_application,
                new AppearanceSettingsStore(Path.Combine(root, "appearance.txt")), () => false, () => false);
            var store = new ControlledProjectSessionStore();
            var session = new ProjectSessionController(store);
            var snapshot = GlobalSnapshot("global");
            store.EnqueueLoadResult(snapshot);
            True(session.LoadTargetAsync(snapshot.Target, false).GetAwaiter().GetResult().Succeeded);
            var window = new MainWindow(string.Empty, manager,
                new RecentProjectsStore(Path.Combine(root, "recent.txt")), session);
            var update = typeof(MainWindow).GetMethod("ApplySessionSnapshotToUi",
                System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!;
            update.Invoke(window, [snapshot]);
            True(window.ProjectNameText.Text.Contains("全局默认", StringComparison.Ordinal));
            Equal(snapshot.ConfigPath, window.ProjectPathText.Text);
            True(window.TrustStatusText.Text.Contains("覆盖", StringComparison.Ordinal));
            True(window.GlobalSettingsButton.IsEnabled);
            var content = (FrameworkElement)window.Content;
            content.Measure(new Size(680, 600));
            content.Arrange(new Rect(0, 0, 680, 600));
            content.UpdateLayout();
            var right = window.GlobalSettingsButton.TranslatePoint(new Point(window.GlobalSettingsButton.ActualWidth, 0), content).X;
            True(right <= content.ActualWidth);
            True(window.GlobalSettingsButton.ActualWidth > 0);
            var renderDirectory = Environment.GetEnvironmentVariable("CONTEXT_MINI_TEST_RENDER_DIRECTORY");
            if (!string.IsNullOrWhiteSpace(renderDirectory))
            {
                Directory.CreateDirectory(renderDirectory);
                content.Measure(new Size(760, 920));
                content.Arrange(new Rect(0, 0, 760, 920));
                content.UpdateLayout();
                var visual = new System.Windows.Media.DrawingVisual();
                using (var drawing = visual.RenderOpen())
                {
                    drawing.DrawRectangle((System.Windows.Media.Brush)window.FindResource("WindowBackgroundBrush"), null,
                        new Rect(0, 0, 760, 920));
                    drawing.DrawRectangle(new System.Windows.Media.VisualBrush(content), null, new Rect(0, 0, 760, 920));
                }
                var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap(760, 920, 96, 96,
                    System.Windows.Media.PixelFormats.Pbgra32);
                bitmap.Render(visual);
                var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
                encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
                using var output = File.Create(Path.Combine(renderDirectory, "global-settings.png"));
                encoder.Save(output);
            }
        });
    }
}
