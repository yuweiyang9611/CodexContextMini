using System.IO;
using System.Windows;
using System.Windows.Media;
using ContextMini.Core;

namespace ContextMini.WpfTests;

internal static class Program
{
    private const string PaletteMarkerKey = "ContextMiniPaletteMarker";

    private static Application _application = null!;
    private static int _passed;
    private static int _failed;

    [STAThread]
    private static int Main()
    {
        _application = new Application();
        Run("manual and system themes switch live", ThemeSwitches);
        Run("failed appearance saves can be retried", SaveFailureCanBeRetried);
        Run("high contrast uses Windows system brushes", HighContrastUsesSystemBrushes);
        Run("theme selector lays out at the minimum window size", ThemeSelectorLayout);
        Run("exact token inputs validate independently and preserve scope", ExactInputsPreserveScope);
        Run("draft rebasing keeps the draft and changes only the baseline", DraftRebaseKeepsDraft);
        Run("managed block previews show scope-preserving changes", ManagedPreviewPreservesScope);
        Run("recent projects are deduplicated and bounded", RecentProjectsAreDeduplicated);
        Run("startup restores the newest recent project or requests selection", StartupProjectResolution);
        Run("session load blocks edits and preserves the captured draft", SessionLoadVsEdit);
        Run("session ignores an old monitor result after apply", SessionApplyVsMonitor);
        Run("session rejects a preview after a byte-identical snapshot replacement", SessionSameBytesInvalidatePreview);
        Run("session preserves the draft through an apply conflict", SessionApplyConflictRecovery);
        Run("session accepts only the newest overlapping project load", SessionContinuousSwitch);
        Run("session close does not cancel an in-flight write", SessionCloseDuringWrite);
        Run("session monitoring recovers after a transient read failure", SessionMonitorErrorRecovery);
        Console.WriteLine($"RESULT passed={_passed} failed={_failed}");
        _application.Shutdown();
        return _failed == 0 ? 0 : 1;
    }

    private static void Run(string name, Action test)
    {
        try
        {
            test();
            _passed++;
            Console.WriteLine($"PASS {name}");
        }
        catch (Exception exception)
        {
            _failed++;
            Console.Error.WriteLine($"FAIL {name}: {exception}");
        }
    }

    private static void ThemeSwitches()
    {
        WithDirectory(root =>
        {
            var systemUsesDark = false;
            var store = new AppearanceSettingsStore(Path.Combine(root, "appearance.txt"));
            var manager = new AppearanceManager(
                _application,
                store,
                () => systemUsesDark,
                () => false);

            Equal(AppearancePreference.System, manager.Preference);
            AssertPalette("Light", "#FFF3F5F8");

            True(manager.SetPreference(AppearancePreference.Dark).Saved);
            Equal(AppearancePreference.Dark, manager.Preference);
            Equal(AppearancePreference.Dark, store.Load());
            AssertPalette("Dark", "#FF090C10");

            True(manager.SetPreference(AppearancePreference.Light).Saved);
            AssertPalette("Light", "#FFF3F5F8");

            systemUsesDark = true;
            True(manager.SetPreference(AppearancePreference.System).Saved);
            AssertPalette("Dark", "#FF090C10");

            systemUsesDark = false;
            manager.RefreshSystemTheme();
            AssertPalette("Light", "#FFF3F5F8");

            True(manager.SetPreference(AppearancePreference.Dark).Saved);
            manager.RefreshSystemTheme();
            AssertPalette("Dark", "#FF090C10");
        });
    }

    private static void SaveFailureCanBeRetried()
    {
        WithDirectory(root =>
        {
            var blockedParent = Path.Combine(root, "settings-parent");
            File.WriteAllText(blockedParent, "not a directory");
            var store = new AppearanceSettingsStore(Path.Combine(blockedParent, "appearance.txt"));
            var manager = new AppearanceManager(_application, store, () => false, () => false);

            var failed = manager.SetPreference(AppearancePreference.Dark);
            False(failed.Saved);
            True(!string.IsNullOrWhiteSpace(failed.ErrorMessage));
            Equal(AppearancePreference.Dark, manager.Preference);

            File.Delete(blockedParent);
            Directory.CreateDirectory(blockedParent);
            var retried = manager.SetPreference(AppearancePreference.Dark);
            True(retried.Saved);
            Equal(AppearancePreference.Dark, store.Load());
        });
    }

    private static void HighContrastUsesSystemBrushes()
    {
        WithDirectory(root =>
        {
            var highContrast = false;
            var store = new AppearanceSettingsStore(Path.Combine(root, "appearance.txt"));
            var manager = new AppearanceManager(
                _application,
                store,
                () => false,
                () => highContrast);
            AssertPalette("Light", "#FFF3F5F8");

            highContrast = true;
            manager.RefreshSystemTheme();
            Equal("HighContrast", CurrentPalette()[PaletteMarkerKey]?.ToString());
            True(ReferenceEquals(SystemColors.WindowTextBrush, _application.TryFindResource("PrimaryTextBrush")));
            True(ReferenceEquals(SystemColors.ControlTextBrush, _application.TryFindResource("ControlTextBrush")));
            True(ReferenceEquals(SystemColors.HighlightTextBrush, _application.TryFindResource("ControlHoverTextBrush")));
            True(ReferenceEquals(SystemColors.HighlightTextBrush, _application.TryFindResource("HeaderControlHoverTextBrush")));
            True(ReferenceEquals(SystemColors.WindowBrush, _application.TryFindResource("AlternateSurfaceBrush")));

            highContrast = false;
            manager.RefreshSystemTheme();
            AssertPalette("Light", "#FFF3F5F8");
        });
    }

    private static void ThemeSelectorLayout()
    {
        WithDirectory(root =>
        {
            var store = new AppearanceSettingsStore(Path.Combine(root, "appearance.txt"));
            var manager = new AppearanceManager(_application, store, () => false, () => false);
            True(manager.SetPreference(AppearancePreference.Dark).Saved);
            var window = new MainWindow(root, manager)
            {
                Width = 680,
                Height = 600,
            };
            var content = window.Content as FrameworkElement
                ?? throw new InvalidOperationException("MainWindow content was not created.");
            content.Measure(new Size(680, 600));
            content.Arrange(new Rect(0, 0, 680, 600));
            content.UpdateLayout();

            True(window.SystemAppearanceButton.ActualWidth > 0);
            True(window.LightAppearanceButton.ActualWidth > 0);
            True(window.DarkAppearanceButton.ActualWidth > 0);
            var selectorRight = window.DarkAppearanceButton
                .TranslatePoint(new Point(window.DarkAppearanceButton.ActualWidth, 0), content).X;
            True(selectorRight <= content.ActualWidth);
            True(!string.IsNullOrWhiteSpace(
                System.Windows.Automation.AutomationProperties.GetName(window.SystemAppearanceButton)));
            Equal(TextTrimming.CharacterEllipsis, window.ProjectNameText.TextTrimming);
            True(window.WindowInputTextBox.ActualWidth > 0);
            True(window.CompactInputTextBox.ActualWidth > 0);
            True(window.RecentProjectsCombo.ActualWidth > 0);
            False(window.WindowInputTextBox.IsEnabled);
            False(window.CompactInputTextBox.IsEnabled);
        });
    }

    private static void ExactInputsPreserveScope()
    {
        True(ContextDraftInput.TryCreate(
            "500,000",
            "310,000",
            ContextPolicy.BodyAfterPrefixScope,
            out var plan,
            out var error));
        Equal(string.Empty, error);
        Equal(500_000L, plan.WindowTokens);
        Equal(310_000L, plan.CompactAtTokens);
        Equal(ContextPolicy.BodyAfterPrefixScope, plan.Scope);
        Equal(ContextProfile.Custom, plan.Profile);

        var preset = ContextDraftInput.FromPreset(
            ContextPolicy.Balanced400K,
            ContextPolicy.BodyAfterPrefixScope);
        Equal(ContextPolicy.Balanced400K.WindowTokens, preset.WindowTokens);
        Equal(ContextPolicy.Balanced400K.CompactAtTokens, preset.CompactAtTokens);
        Equal(ContextPolicy.BodyAfterPrefixScope, preset.Scope);
        Equal(ContextProfile.Custom, preset.Profile);

        False(ContextDraftInput.TryCreate(
            "10,,000",
            "9,000",
            ContextPolicy.TotalScope,
            out _,
            out _));
        False(ContextDraftInput.TryCreate(
            "4,00,000",
            "320,000",
            ContextPolicy.TotalScope,
            out _,
            out _));

        False(ContextDraftInput.TryCreate(
            "500000",
            "500000",
            ContextPolicy.TotalScope,
            out _,
            out var invalidError));
        True(!string.IsNullOrWhiteSpace(invalidError));
    }

    private static void DraftRebaseKeepsDraft()
    {
        var draft = new ContextPlan(
            ContextProfile.Custom,
            500_000,
            310_000,
            ContextPolicy.BodyAfterPrefixScope);
        var latestDocument = new ManagedConfigEditor().Analyze(
            $"{ManagedConfigEditor.MiniBeginMarker}\n" +
            "model_context_window = 400000\n" +
            "model_auto_compact_token_limit = 320000\n" +
            "model_auto_compact_token_limit_scope = \"total\"\n" +
            $"{ManagedConfigEditor.MiniEndMarker}\n");
        var latest = new ConfigSnapshot(
            "C:\\project",
            "C:\\project\\.codex\\config.toml",
            true,
            "latest",
            false,
            [],
            latestDocument);

        var rebased = DraftStateRules.Rebase(draft, latest);
        True(ReferenceEquals(draft, rebased.Draft));
        True(ReferenceEquals(latest, rebased.Snapshot));
        True(rebased.IsDirty);

        var pending = latest with { Fingerprint = "pending" };
        var restoredBaseline = latest with { Fingerprint = "latest" };
        Equal(
            ExternalSnapshotRelation.BaselineEquivalent,
            DraftStateRules.RelateExternalSnapshot(latest, pending, restoredBaseline));

        var outOfRangeLegacy = new ManagedConfigEditor().Analyze(
            $"{ManagedConfigEditor.LegacyBeginMarker}\n" +
            "model_context_window = 2000000\n" +
            "model_auto_compact_token_limit = 1500000\n" +
            "model_auto_compact_token_limit_scope = \"body_after_prefix\"\n" +
            $"{ManagedConfigEditor.LegacyEndMarker}\n");
        var preservedScope = ContextDraftInput.NormalizeScope(outOfRangeLegacy.Scope);
        Equal(ContextPolicy.BodyAfterPrefixScope, preservedScope);
        Equal(
            ContextPolicy.BodyAfterPrefixScope,
            ContextDraftInput.FromPreset(ContextPolicy.Balanced400K, preservedScope).Scope);
    }

    private static void ManagedPreviewPreservesScope()
    {
        var text =
            $"{ManagedConfigEditor.LegacyBeginMarker}\n" +
            "model_context_window = 500000\n" +
            "model_auto_compact_token_limit = 300000\n" +
            "model_auto_compact_token_limit_scope = \"body_after_prefix\"\n" +
            $"{ManagedConfigEditor.LegacyEndMarker}\n" +
            "model = \"gpt-test\"\n";
        var document = new ManagedConfigEditor().Analyze(text);
        var snapshot = new ConfigSnapshot(
            "C:\\project",
            "C:\\project\\.codex\\config.toml",
            true,
            "before",
            false,
            [],
            document);
        var draft = new ContextPlan(
            ContextProfile.Custom,
            510_000,
            320_000,
            ContextPolicy.BodyAfterPrefixScope);

        var preview = ConfigurationPresentation.BuildManagedBlockPreview(snapshot, draft);
        True(preview.Contains("变更前的受管块", StringComparison.Ordinal));
        True(preview.Contains("变更后的受管块", StringComparison.Ordinal));
        True(preview.Contains("model_context_window = 510000", StringComparison.Ordinal));
        True(preview.Contains(
            "model_auto_compact_token_limit_scope = \"body_after_prefix\"",
            StringComparison.Ordinal));
        False(preview.Contains("model = \"gpt-test\"", StringComparison.Ordinal));

        var beforeLargeText = new string('a', 13_000) + "BEFORE_ONLY" + new string('z', 13_000);
        var afterLargeText = new string('a', 13_000) + "AFTER_ONLY" + new string('z', 13_000);
        var beforeLarge = snapshot with
        {
            Fingerprint = "before-large",
            Document = new ManagedConfigEditor().Analyze(beforeLargeText),
        };
        var afterLarge = snapshot with
        {
            Fingerprint = "after-large",
            Document = new ManagedConfigEditor().Analyze(afterLargeText),
        };
        var externalPreview = ConfigurationPresentation.BuildExternalChangePreview(beforeLarge, afterLarge);
        True(externalPreview.Contains("BEFORE", StringComparison.Ordinal));
        True(externalPreview.Contains("AFTER", StringComparison.Ordinal));
        True(externalPreview.Contains("<<< 变化区域开始 >>>", StringComparison.Ordinal));
        True(externalPreview.Length < 24_000);

        var sameTextDocument = new ManagedConfigEditor().Analyze("model = \"test\"\n");
        var withoutBom = snapshot with
        {
            Fingerprint = "without-bom",
            HasUtf8Bom = false,
            SourceBytes = [0x6D],
            Document = sameTextDocument,
        };
        var withBom = snapshot with
        {
            Fingerprint = "with-bom",
            HasUtf8Bom = true,
            SourceBytes = [0xEF, 0xBB, 0xBF, 0x6D],
            Document = sameTextDocument,
        };
        var bomPreview = ConfigurationPresentation.BuildExternalChangePreview(withoutBom, withBom);
        True(bomPreview.Contains("UTF-8 BOM 已添加", StringComparison.Ordinal));
        False(bomPreview.Contains("字节内容相同", StringComparison.Ordinal));
    }

    private static void RecentProjectsAreDeduplicated()
    {
        WithDirectory(root =>
        {
            var settings = Path.Combine(root, "settings", "recent-projects.txt");
            var store = new RecentProjectsStore(settings);
            var projects = Enumerable.Range(0, RecentProjectsStore.MaximumEntries + 2)
                .Select(index => Directory.CreateDirectory(Path.Combine(root, $"project-{index}")).FullName)
                .ToArray();

            foreach (var project in projects) store.Remember(project);
            store.Remember(projects[^1]);

            var loaded = store.Load();
            Equal(RecentProjectsStore.MaximumEntries, loaded.Count);
            Equal(projects[^1], loaded[0]);
            Equal(1, loaded.Count(path =>
                string.Equals(path, projects[^1], StringComparison.OrdinalIgnoreCase)));
            False(loaded.Contains(projects[0], StringComparer.OrdinalIgnoreCase));

            using (var reader = new FileStream(
                       settings,
                       FileMode.Open,
                       FileAccess.Read,
                       FileShare.Read | FileShare.Delete))
            {
                store.Remember(projects[0]);
                Equal(projects[0], store.Load()[0]);
            }
            EventuallyNoAtomicArtifacts(Path.GetDirectoryName(settings)!);
        });
    }

    private static void EventuallyNoAtomicArtifacts(string directory)
    {
        for (var attempt = 0; attempt < 40; attempt++)
        {
            var artifacts = Directory.EnumerateFiles(directory)
                .Where(path => path.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase) ||
                               path.EndsWith(".bak", StringComparison.OrdinalIgnoreCase))
                .ToArray();
            if (artifacts.Length == 0) return;
            if (attempt < 39) Thread.Sleep(50);
        }
        throw new InvalidOperationException("Recent-project atomic artifacts did not disappear within two seconds.");
    }

    private static void StartupProjectResolution()
    {
        WithDirectory(root =>
        {
            var project = Directory.CreateDirectory(Path.Combine(root, "remembered-project")).FullName;
            var populated = new RecentProjectsStore(Path.Combine(root, "populated", "recent-projects.txt"));
            populated.Remember(project);

            Equal(project, App.ResolveInitialProject([], populated));
            Equal("D:\\explicit-project", App.ResolveInitialProject(["D:\\explicit-project"], populated));

            var empty = new RecentProjectsStore(Path.Combine(root, "empty", "recent-projects.txt"));
            Equal(string.Empty, App.ResolveInitialProject([], empty));
        });
    }

    private static void SessionLoadVsEdit()
    {
        var store = new ControlledProjectSessionStore();
        var session = new ProjectSessionController(store);
        var baseline = Snapshot("C:\\session-a", "baseline", 400_000, 320_000);
        store.EnqueueLoadResult(baseline);
        True(session.LoadProjectAsync(baseline.ProjectRoot, preserveDraft: false).GetAwaiter().GetResult().Succeeded);

        var draft = new ContextPlan(ContextProfile.Custom, 500_000, 310_000, ContextPolicy.BodyAfterPrefixScope);
        True(session.TrySetDraft(draft));
        var pendingLoad = store.EnqueuePendingLoad();
        var reload = session.LoadProjectAsync(baseline.ProjectRoot, preserveDraft: true);

        True(session.IsLoadBusy);
        False(session.TrySetDraft(ContextPolicy.Compact128K));
        var latest = Snapshot(baseline.ProjectRoot, "latest", 420_000, 330_000);
        pendingLoad.SetResult(latest);
        var outcome = reload.GetAwaiter().GetResult();

        True(outcome.Succeeded);
        Equal(draft, session.Draft);
        Equal(ContextPolicy.BodyAfterPrefixScope, session.DraftScope);
        True(session.IsDirty);
        False(session.IsLoadBusy);
    }

    private static void SessionApplyVsMonitor()
    {
        var store = new ControlledProjectSessionStore();
        var session = LoadedSession(store, Snapshot("C:\\session-apply", "baseline", 400_000, 320_000));
        True(session.TrySetDraft(ContextPolicy.Compact128K));

        var monitorLoad = store.EnqueuePendingLoad();
        var monitor = session.MonitorAsync();
        var pendingApply = store.EnqueuePendingApply();
        var apply = session.ApplyAsync();
        var applied = Snapshot(session.ProjectRoot!, "applied", 128_000, 96_000);
        pendingApply.SetResult(new ApplyResult(true, applied));
        True(apply.GetAwaiter().GetResult().Succeeded);

        monitorLoad.SetResult(Snapshot(session.ProjectRoot!, "stale-monitor", 410_000, 325_000));
        Equal(SessionMonitorKind.Superseded, monitor.GetAwaiter().GetResult().Kind);
        Equal("applied", session.Snapshot!.Fingerprint);
        False(session.HasExternalConflict);
    }

    private static void SessionSameBytesInvalidatePreview()
    {
        var store = new ControlledProjectSessionStore();
        var baseline = Snapshot("C:\\session-identity", "same-bytes", 400_000, 320_000);
        var session = LoadedSession(store, baseline);
        True(session.TrySetDraft(ContextPolicy.Compact128K));
        var ticket = session.TryCreateApplyTicket()
            ?? throw new InvalidOperationException("Expected an apply preview ticket.");

        var replacement = Snapshot(baseline.ProjectRoot, "same-bytes", 400_000, 320_000);
        False(ReferenceEquals(baseline, replacement));
        store.EnqueueLoadResult(replacement);
        Equal(SessionMonitorKind.Unchanged, session.MonitorAsync().GetAwaiter().GetResult().Kind);

        Equal(SessionApplyKind.StalePreview, session.ApplyAsync(ticket).GetAwaiter().GetResult().Kind);
        Equal(0, store.ApplyCallCount);
        True(ReferenceEquals(replacement, session.Snapshot));
        True(session.IsDirty);
    }

    private static void SessionApplyConflictRecovery()
    {
        var store = new ControlledProjectSessionStore();
        var baseline = Snapshot("C:\\session-conflict", "baseline", 400_000, 320_000);
        var session = LoadedSession(store, baseline);
        var draft = ContextPolicy.Compact128K;
        True(session.TrySetDraft(draft));

        var latest = Snapshot(baseline.ProjectRoot, "external", 420_000, 330_000);
        store.EnqueueApplyError(new ConfigConflictException("external replacement"));
        store.EnqueueLoadResult(latest);
        var failed = session.ApplyAsync().GetAwaiter().GetResult();

        Equal(SessionApplyKind.Failed, failed.Kind);
        True(failed.PendingSnapshotAvailable);
        True(session.HasExternalConflict);
        True(ReferenceEquals(latest, session.PendingExternalSnapshot));
        Equal(draft, session.Draft);
        False(session.CanApply);

        True(session.TryRebasePending());
        False(session.HasExternalConflict);
        True(ReferenceEquals(latest, session.Snapshot));
        Equal(draft, session.Draft);
        True(session.IsDirty);
        True(session.CanApply);
    }

    private static void SessionContinuousSwitch()
    {
        var store = new ControlledProjectSessionStore();
        var session = new ProjectSessionController(store);
        var firstLoad = store.EnqueuePendingLoad();
        var first = session.LoadProjectAsync("C:\\project-one", preserveDraft: false);
        var secondLoad = store.EnqueuePendingLoad();
        var second = session.LoadProjectAsync("C:\\project-two", preserveDraft: false);

        secondLoad.SetResult(Snapshot("C:\\project-two", "second", 400_000, 320_000));
        True(second.GetAwaiter().GetResult().Succeeded);
        firstLoad.SetResult(Snapshot("C:\\project-one", "first", 128_000, 96_000));
        True(first.GetAwaiter().GetResult().Superseded);

        Equal("C:\\project-two", session.ProjectRoot);
        Equal("second", session.Snapshot!.Fingerprint);
        False(session.IsLoadBusy);
    }

    private static void SessionCloseDuringWrite()
    {
        var store = new ControlledProjectSessionStore();
        var session = LoadedSession(store, Snapshot("C:\\session-close", "baseline", 400_000, 320_000));
        True(session.TrySetDraft(ContextPolicy.Compact128K));
        var pendingApply = store.EnqueuePendingApply();
        var apply = session.ApplyAsync();

        True(session.IsApplyBusy);
        False(session.CanClose);
        session.Close();
        var applied = Snapshot(session.ProjectRoot!, "written-after-close", 128_000, 96_000);
        pendingApply.SetResult(new ApplyResult(true, applied));
        True(apply.GetAwaiter().GetResult().Superseded);
        True(session.IsClosed);
        Equal("baseline", session.Snapshot!.Fingerprint);
        Equal(1, store.ApplyCallCount);
    }

    private static void SessionMonitorErrorRecovery()
    {
        var store = new ControlledProjectSessionStore();
        var baseline = Snapshot("C:\\session-recovery", "baseline", 400_000, 320_000);
        var session = LoadedSession(store, baseline);
        True(session.TrySetDraft(ContextPolicy.Compact128K));

        store.EnqueueLoadError(new IOException("transient monitor failure"));
        var failed = session.MonitorAsync().GetAwaiter().GetResult();
        Equal(SessionMonitorKind.Failed, failed.Kind);
        True(session.HasExternalConflict);
        True(session.PendingExternalSnapshot is null);
        True(session.IsDirty);

        store.EnqueueLoadResult(baseline);
        var recovered = session.MonitorAsync().GetAwaiter().GetResult();
        Equal(SessionMonitorKind.Recovered, recovered.Kind);
        False(session.HasExternalConflict);
        True(session.IsDirty);
        Equal(ContextPolicy.Compact128K, session.Draft);
    }

    private static ProjectSessionController LoadedSession(
        ControlledProjectSessionStore store,
        ConfigSnapshot snapshot)
    {
        var session = new ProjectSessionController(store);
        store.EnqueueLoadResult(snapshot);
        True(session.LoadProjectAsync(snapshot.ProjectRoot, preserveDraft: false).GetAwaiter().GetResult().Succeeded);
        return session;
    }

    private static ConfigSnapshot Snapshot(
        string projectRoot,
        string fingerprint,
        long window,
        long compact)
    {
        var text =
            $"{ManagedConfigEditor.MiniBeginMarker}\n" +
            $"model_context_window = {window}\n" +
            $"model_auto_compact_token_limit = {compact}\n" +
            "model_auto_compact_token_limit_scope = \"total\"\n" +
            $"{ManagedConfigEditor.MiniEndMarker}\n";
        return new ConfigSnapshot(
            projectRoot,
            Path.Combine(projectRoot, ".codex", "config.toml"),
            true,
            fingerprint,
            false,
            System.Text.Encoding.UTF8.GetBytes(text),
            new ManagedConfigEditor().Analyze(text));
    }

    private static void AssertPalette(string expectedName, string expectedWindowColor)
    {
        Equal(expectedName, CurrentPalette()[PaletteMarkerKey]?.ToString());
        var brush = _application.TryFindResource("WindowBackgroundBrush") as SolidColorBrush
            ?? throw new InvalidOperationException("WindowBackgroundBrush was not resolved.");
        Equal(expectedWindowColor, brush.Color.ToString());
    }

    private static ResourceDictionary CurrentPalette() =>
        _application.Resources.MergedDictionaries.LastOrDefault(dictionary => dictionary.Contains(PaletteMarkerKey))
        ?? throw new InvalidOperationException("The Context Mini palette was not installed.");

    private static void WithDirectory(Action<string> action)
    {
        var root = Directory.CreateTempSubdirectory("context-mini-wpf-tests-").FullName;
        try
        {
            action(root);
        }
        finally
        {
            TryDelete(root);
        }
    }

    private static void TryDelete(string root)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                if (Directory.Exists(root)) Directory.Delete(root, true);
                return;
            }
            catch (IOException) when (attempt < 4)
            {
                Thread.Sleep(50);
            }
        }
    }

    private static void True(bool value)
    {
        if (!value) throw new InvalidOperationException("Expected true.");
    }

    private static void False(bool value) => True(!value);

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"Expected '{expected}', got '{actual}'.");
        }
    }
}

internal sealed class ControlledProjectSessionStore : IProjectSessionStore
{
    private readonly Queue<Func<Task<ConfigSnapshot>>> _loads = new();
    private readonly Queue<Func<Task<ApplyResult>>> _applies = new();

    public int ApplyCallCount { get; private set; }

    public Task<ConfigSnapshot> LoadAsync(string projectRoot)
    {
        if (_loads.Count == 0)
        {
            throw new InvalidOperationException($"No controlled load was queued for {projectRoot}.");
        }
        return _loads.Dequeue()();
    }

    public Task<ApplyResult> ApplyAsync(ConfigSnapshot expected, ContextPlan plan)
    {
        ApplyCallCount++;
        if (_applies.Count == 0)
        {
            throw new InvalidOperationException("No controlled apply was queued.");
        }
        return _applies.Dequeue()();
    }

    public void EnqueueLoadResult(ConfigSnapshot snapshot) =>
        _loads.Enqueue(() => Task.FromResult(snapshot));

    public void EnqueueLoadError(Exception exception) =>
        _loads.Enqueue(() => Task.FromException<ConfigSnapshot>(exception));

    public TaskCompletionSource<ConfigSnapshot> EnqueuePendingLoad()
    {
        var completion = new TaskCompletionSource<ConfigSnapshot>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        _loads.Enqueue(() => completion.Task);
        return completion;
    }

    public TaskCompletionSource<ApplyResult> EnqueuePendingApply()
    {
        var completion = new TaskCompletionSource<ApplyResult>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        _applies.Enqueue(() => completion.Task);
        return completion;
    }

    public void EnqueueApplyError(Exception exception) =>
        _applies.Enqueue(() => Task.FromException<ApplyResult>(exception));
}
