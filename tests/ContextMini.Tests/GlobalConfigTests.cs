using ContextMini.Core;

namespace ContextMini.Tests;

internal static partial class Program
{
    private static void RunGlobalTests()
    {
        Run("global location resolves user profile and custom CODEX_HOME", GlobalLocation);
        Run("global reads and Auto create nothing", GlobalReadOnly);
        Run("global writes preserve bytes and remain separate from projects", GlobalIsolation);
        Run("global stale snapshots and atomic races preserve external edits", GlobalConflicts);
        Run("global unsafe paths and conflicting keys are rejected", GlobalSafety);
        Run("global apply uses the captured configuration location", GlobalCapturedLocation);
    }

    private static void GlobalLocation()
    {
        WithProject(root =>
        {
            var standard = ConfigTarget.ResolveGlobal(null, root);
            Equal(Path.Combine(root, ".codex", "config.toml"), standard.ConfigPath);
            var custom = ConfigTarget.ResolveGlobal(Path.Combine(root, "custom-home"), root);
            Equal(Path.Combine(root, "custom-home", "config.toml"), custom.ConfigPath);
            True(custom.IsGlobal);
            Throws<UnsafeProjectException>(() => ConfigTarget.ResolveGlobal("relative-home", root));
            Throws<UnsafeProjectException>(() => ConfigTarget.ResolveGlobal(null, string.Empty));
        });
    }

    private static void GlobalReadOnly()
    {
        WithProject(root =>
        {
            var target = ConfigTarget.ResolveGlobal(null, root);
            var store = new ProjectConfigStore();
            var snapshot = store.Load(target);
            Equal(ConfigurationScope.Global, snapshot.ConfigurationScope);
            False(snapshot.Exists);
            False(store.Apply(snapshot, ContextPolicy.Auto).Changed);
            False(Directory.Exists(target.ConfigDirectory));
            var applied = store.Apply(snapshot, ContextPolicy.OneMillion);
            True(applied.Changed);
            Equal(1_050_000L, store.Load(target).Document.WindowTokens);
            False(Directory.Exists(Path.Combine(target.Root, ".codex")));
            True(store.Apply(applied.Snapshot, ContextPolicy.Auto).Changed);
            False(File.Exists(target.ConfigPath));
        });
    }

    private static void GlobalIsolation()
    {
        WithProject(root =>
        {
            var target = ConfigTarget.ResolveGlobal(Path.Combine(root, "user-config"), root);
            Directory.CreateDirectory(target.Root);
            var original = Utf8Bom.Concat(Utf8NoBom.GetBytes("# user settings\r\nmodel = \"example\"\r\n[features]\r\nexample = true\r\n")).ToArray();
            File.WriteAllBytes(target.ConfigPath, original);
            var project = Directory.CreateDirectory(Path.Combine(root, "project")).FullName;
            var store = new ProjectConfigStore();
            store.Apply(store.Load(project), ContextPolicy.Compact128K);
            var projectBytes = File.ReadAllBytes(ConfigPath(project));
            var global = store.Apply(store.Load(target), ContextPolicy.Balanced400K).Snapshot;
            Equal(target.ConfigPath, global.ConfigPath);
            True(global.HasUtf8Bom);
            Equal("\r\n", global.Document.NewLine);
            False(store.Apply(global, ContextPolicy.Balanced400K).Changed);
            SequenceEqual(projectBytes, File.ReadAllBytes(ConfigPath(project)));
            store.Apply(global, ContextPolicy.Auto);
            SequenceEqual(original, File.ReadAllBytes(target.ConfigPath));
            SequenceEqual(projectBytes, File.ReadAllBytes(ConfigPath(project)));
        });
    }

    private static void GlobalConflicts()
    {
        WithProject(root =>
        {
            var target = ConfigTarget.ResolveGlobal(null, root);
            var store = new ProjectConfigStore();
            var baseline = store.Apply(store.Load(target), ContextPolicy.Balanced400K).Snapshot;
            File.AppendAllText(target.ConfigPath, "# external change\n");
            var external = File.ReadAllBytes(target.ConfigPath);
            Throws<ConfigConflictException>(() => store.Apply(baseline, ContextPolicy.OneMillion));
            SequenceEqual(external, File.ReadAllBytes(target.ConfigPath));
            var race = new ProjectConfigStore(path => File.AppendAllText(path, "# race\n"));
            Throws<ConfigConflictException>(() => race.Apply(race.Load(target), ContextPolicy.OneMillion));
            True(File.ReadAllText(target.ConfigPath).EndsWith("# race\n", StringComparison.Ordinal));
        });
    }

    private static void GlobalSafety()
    {
        WithProject(root =>
        {
            var store = new ProjectConfigStore();
            Throws<UnsafeProjectException>(() => store.Load(new ConfigTarget(ConfigurationScope.Global, Path.GetPathRoot(root)!)));
            Throws<UnsafeProjectException>(() => store.Load(new ConfigTarget(ConfigurationScope.Global, @"\\server\share\codex")));
            var target = ConfigTarget.ResolveGlobal(null, root);
            Directory.CreateDirectory(target.Root);
            File.WriteAllText(target.ConfigPath, "model_context_window = 400000\n");
            var bytes = File.ReadAllBytes(target.ConfigPath);
            var baseline = store.Load(target);
            False(baseline.Document.CanWrite);
            Throws<ConfigConflictException>(() => store.Apply(baseline, ContextPolicy.OneMillion));
            SequenceEqual(bytes, File.ReadAllBytes(target.ConfigPath));
        });
    }

    private static void GlobalCapturedLocation()
    {
        WithProject(root =>
        {
            var first = ConfigTarget.ResolveGlobal(Path.Combine(root, "first"), root);
            var second = ConfigTarget.ResolveGlobal(Path.Combine(root, "second"), root);
            var store = new ProjectConfigStore();
            var snapshot = store.Load(first);
            store.Load(second);
            var result = store.Apply(snapshot, ContextPolicy.Compact128K);
            Equal(first.ConfigPath, result.Snapshot.ConfigPath);
            True(File.Exists(first.ConfigPath));
            False(Directory.Exists(second.Root));
        });
    }
}
