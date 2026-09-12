using ContextMini.Core;

namespace ContextMini.Tests;

internal static partial class Program
{
    private static void RunTomlStringTests()
    {
        Run("multiline TOML examples round-trip in global and project configs", MultilineExamplesRoundTrip);
        Run("TOML quote boundaries preserve real conflict detection", StringBoundaries);
        Run("ambiguous TOML strings and actual markers remain read-only", InvalidStringsRemainReadOnly);
    }

    private static string ExampleText(string delimiter) =>
        "instructions = " + delimiter + "\n" +
        "model_context_window = 128000\n" +
        "[model_auto_compact_token_limit]\n" +
        "[[model_context_window]]\n" +
        "# examples = not configuration\n" +
        ManagedConfigEditor.MiniBeginMarker + "\n" +
        ManagedConfigEditor.MiniEndMarker + "\n" +
        ManagedConfigEditor.LegacyBeginMarker + "\n" +
        ManagedConfigEditor.LegacyEndMarker + "\n" +
        "# >>> codex-context-mini:v99\n" +
        delimiter + "\nmodel = \"example\"";

    private static void MultilineExamplesRoundTrip()
    {
        foreach (var delimiter in new[] { "\"\"\"", "'''" })
        foreach (var global in new[] { false, true })
        foreach (var bom in new[] { false, true })
        foreach (var newline in new[] { "\n", "\r\n" })
        foreach (var trailingNewline in new[] { false, true })
        {
            WithProject(root =>
            {
                var target = global ? new ConfigTarget(ConfigurationScope.Global, root) : ConfigTarget.ForProject(root);
                Directory.CreateDirectory(target.ConfigDirectory);
                var text = ExampleText(delimiter).Replace("\n", newline) + (trailingNewline ? newline : "");
                var original = (bom ? Utf8Bom : Array.Empty<byte>()).Concat(Utf8NoBom.GetBytes(text)).ToArray();
                File.WriteAllBytes(target.ConfigPath, original);
                var store = new ProjectConfigStore();
                var loaded = store.Load(target);
                True(loaded.Document.CanWrite);
                var applied = store.Apply(loaded, ContextPolicy.Balanced400K);
                True(applied.Changed);
                Equal(text, applied.Snapshot.Document.SuffixText);
                False(store.Apply(applied.Snapshot, ContextPolicy.Balanced400K).Changed);
                store.Apply(store.Load(target), ContextPolicy.Auto);
                SequenceEqual(original, File.ReadAllBytes(target.ConfigPath));
            });
        }
    }

    private static void StringBoundaries()
    {
        var valid = new[]
        {
            "note = \"# >>> codex-context-mini:v1\"\n",
            "note = '# <<< context-window-manager'\n",
            "note = \"escaped \\\" quote # model_context_window = 1\"\n",
            "note = \"\"\"\nmodel_context_window = 1\n\"\"\"\n",
            "note = \"\"\"escaped \\\"\"\"\nmodel_context_window = 1\n\"\"\"\n",
            "note = \"\"\"continued \\\n  model_context_window = 1\n\"\"\"\n",
            "note = \"\"\"continued \\  \r\n  model_context_window = 1\r\n\"\"\"\r\n",
            "note = \"\"\"one \" and two \"\" quotes\"\"\"\n",
            "note = \"\"\"four\"\"\"\"\n",
            "note = \"\"\"five\"\"\"\"\"\n",
            "note = '''one ' and two '' quotes'''\n",
            "note = '''four''''\n",
            "note = '''five'''''\n",
            "note = \"\"\"\"\"\"\n",
            "note = ''''''\n",
            "# an unmatched quote \" in a comment\nmodel = 'example'\n",
        };
        var conflicts = new[]
        {
            "model_context_window = 128000\n",
            "model_auto_compact_token_limit = 96000\n",
            "[model_context_window]\nvalue = 1\n",
            "[[model_auto_compact_token_limit]]\nvalue = 1\n",
            "model_context_window.child = 1\n",
            "\"model_\\u0063ontext_window\" = 1\n",
        };
        var editor = new ManagedConfigEditor();
        foreach (var text in valid)
        {
            True(editor.Analyze(text).CanWrite);
            foreach (var conflict in conflicts)
                False(editor.Analyze(text + conflict).CanWrite);
            var managed = editor.Render(editor.Analyze(text), ContextPolicy.Balanced400K);
            True(editor.Analyze(managed).CanWrite);
            foreach (var conflict in conflicts)
                False(editor.Analyze(managed + conflict).CanWrite);
        }
        var legacy = ManagedConfigEditor.LegacyBeginMarker + "\nmodel_context_window = 400000\n" +
            "model_auto_compact_token_limit = 320000\nmodel_auto_compact_token_limit_scope = \"total\"\n" +
            ManagedConfigEditor.LegacyEndMarker + "\n" + ExampleText("'''");
        var migrated = editor.Render(editor.Analyze(legacy), ContextPolicy.Balanced400K);
        True(editor.Analyze(migrated).CanWrite);
        Equal(ExampleText("'''"), editor.Analyze(migrated).SuffixText);
    }

    private static void InvalidStringsRemainReadOnly()
    {
        var cases = new[]
        {
            "note = \"unterminated",
            "note = 'unterminated",
            "note = \"\"\"unterminated",
            "note = '''unterminated",
            "note = \"newline\ninside\"",
            "note = 'newline\ninside'",
            "note = \"escape\\\ninside\"",
            "note = \"\"\"escaped ending \\\"\"\"",
            ExampleText("'''") + "\n" + ManagedConfigEditor.MiniBeginMarker,
            ExampleText("\"\"\"") + "\n# >>> codex-context-mini:v99\n",
        };
        foreach (var text in cases)
        foreach (var global in new[] { false, true })
        {
            WithProject(root =>
            {
                var target = global ? new ConfigTarget(ConfigurationScope.Global, root) : ConfigTarget.ForProject(root);
                Directory.CreateDirectory(target.ConfigDirectory);
                var bytes = Utf8NoBom.GetBytes(text);
                File.WriteAllBytes(target.ConfigPath, bytes);
                var store = new ProjectConfigStore();
                var snapshot = store.Load(target);
                False(snapshot.Document.CanWrite);
                True(!string.IsNullOrWhiteSpace(snapshot.Document.Warning));
                Throws<ConfigConflictException>(() => store.Apply(snapshot, ContextPolicy.Balanced400K));
                SequenceEqual(bytes, File.ReadAllBytes(target.ConfigPath));
            });
        }
        var editor = new ManagedConfigEditor();
        var block = editor.Render(editor.Analyze(""), ContextPolicy.Balanced400K);
        False(editor.Analyze(block + block).CanWrite);
        False(editor.Analyze(block.Replace(ManagedConfigEditor.MiniEndMarker,
            ManagedConfigEditor.MiniEndMarker + "-broken")).CanWrite);
        False(editor.Analyze(block + "note = '''unterminated").CanWrite);
        False(editor.Analyze(block + "# >>> codex-context-mini:v99\n").CanWrite);
    }
}
