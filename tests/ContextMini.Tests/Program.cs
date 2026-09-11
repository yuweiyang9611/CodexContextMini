using System.Text;
using ContextMini.Core;

namespace ContextMini.Tests;

internal static partial class Program
{
    private static readonly UTF8Encoding Utf8NoBom = new(false);
    private static readonly byte[] Utf8Bom = [0xEF, 0xBB, 0xBF];
    private static int _passed;
    private static int _failed;

    private static int Main()
    {
        RunGlobalTests();
        Run("policy presets and custom bounds", PolicyPresets);
        Run("appearance preferences parse and resolve", AppearancePreferences);
        Run("appearance settings round-trip safely", AppearanceSettingsRoundTrip);
        Run("balanced apply preserves unrelated TOML", BalancedApplyPreservesToml);
        Run("Auto removes only the managed block", AutoRemovesManagedBlock);
        Run("Auto on a missing config creates nothing", AutoMissingCreatesNothing);
        Run("manual managed keys make the config read-only", ManualConflictRejected);
        Run("table, dotted, and escaped context keys are rejected", ComplexConflictsRejected);
        Run("near-limit output is rejected before writing", NearLimitOutputRejected);
        Run("malformed markers are never overwritten", MalformedMarkersRejected);
        Run("legacy plugin blocks migrate to Mini", LegacyBlockMigrates);
        Run("legacy body-after-prefix scope survives migration", LegacyBodyScopeSurvivesMigration);
        Run("stale snapshots reject external writes", StaleSnapshotRejected);
        Run("UTF-8 BOM and CRLF survive apply/reset", BomAndCrlfPreserved);
        Run("BOM-only Auto is a byte-for-byte no-op", BomOnlyAutoNoOp);
        Run("lock-window external writes are preserved", ConcurrentExternalWritePreserved);
        Run("out-of-range legacy blocks can be removed", OutOfRangeLegacyCanBeRemoved);
        Run("an active project lock rejects concurrent apply", ActiveLockRejected);
        Run("oversized configs are rejected", OversizedConfigRejected);
        Run("config reads stop at the bounded limit", ConfigReadStopsAtBoundedLimit);
        Run("invalid UTF-8 is rejected", InvalidUtf8Rejected);
        Run("unsafe .codex/config path shapes are rejected", UnsafePathShapesRejected);
        Run("filesystem roots are rejected as projects", FilesystemRootRejected);
        Run("mapped network drives are rejected", MappedNetworkDriveRejected);
        Run("filesystem identity rejects reparse points and type changes", FileSystemIdentityAttributesRejected);
        Run("same-byte config replacement is detected", SameByteReplacementDetected);
        Run("missing config rejects a replaced .codex directory", MissingConfigDirectoryReplacementDetected);
        Run("unexpected legacy content is rejected", UnexpectedLegacyContentRejected);
        Run("reapplying the same plan is idempotent", ReapplyIsIdempotent);
        Run("atomic writes leave no temporary artifacts", AtomicWriteLeavesNoArtifacts);
        Console.WriteLine($"RESULT passed={_passed} failed={_failed}");
        return _failed == 0 ? 0 : 1;
    }

    private static void Run(string name, Action test)
    {
        try { test(); _passed++; Console.WriteLine($"PASS {name}"); }
        catch (Exception exception) { _failed++; Console.Error.WriteLine($"FAIL {name}: {exception}"); }
    }

    private static void PolicyPresets()
    {
        Equal(128_000L, ContextPolicy.Compact128K.WindowTokens);
        Equal(96_000L, ContextPolicy.Compact128K.CompactAtTokens);
        Equal(400_000L, ContextPolicy.Balanced400K.WindowTokens);
        Equal(320_000L, ContextPolicy.Balanced400K.CompactAtTokens);
        Equal(1_050_000L, ContextPolicy.OneMillion.WindowTokens);
        Equal(850_000L, ContextPolicy.OneMillion.CompactAtTokens);
        Equal(80_000L, ContextPolicy.Custom(100_000).CompactAtTokens);
        Throws<ArgumentOutOfRangeException>(() => ContextPolicy.Custom(8_191));
        Throws<ArgumentOutOfRangeException>(() => ContextPolicy.Custom(1_050_001));
    }

    private static void AppearancePreferences()
    {
        Equal(AppearancePreference.System, AppearancePreferenceCodec.ParseOrSystem(null));
        Equal(AppearancePreference.System, AppearancePreferenceCodec.ParseOrSystem("unknown"));
        True(AppearancePreferenceCodec.TryParse(" DARK ", out var dark));
        Equal(AppearancePreference.Dark, dark);
        True(AppearancePreferenceCodec.TryParse("Light", out var light));
        Equal(AppearancePreference.Light, light);
        False(AppearancePreferenceCodec.TryParse("sepia", out var fallback));
        Equal(AppearancePreference.System, fallback);
        Equal("system", AppearancePreferenceCodec.Format(AppearancePreference.System));
        Equal("light", AppearancePreferenceCodec.Format(AppearancePreference.Light));
        Equal("dark", AppearancePreferenceCodec.Format(AppearancePreference.Dark));
        True(AppearancePreferenceCodec.ResolveDark(AppearancePreference.System, true));
        False(AppearancePreferenceCodec.ResolveDark(AppearancePreference.System, false));
        False(AppearancePreferenceCodec.ResolveDark(AppearancePreference.Light, true));
        True(AppearancePreferenceCodec.ResolveDark(AppearancePreference.Dark, false));
        Throws<ArgumentOutOfRangeException>(() =>
            AppearancePreferenceCodec.Format((AppearancePreference)99));
    }

    private static void AppearanceSettingsRoundTrip()
    {
        WithProject(root =>
        {
            var path = Path.Combine(root, "preferences", "appearance.txt");
            var store = new AppearanceSettingsStore(path);
            Equal(AppearancePreference.System, store.Load());

            foreach (var preference in Enum.GetValues<AppearancePreference>())
            {
                store.Save(preference);
                Equal(preference, store.Load());
                Equal(AppearancePreferenceCodec.Format(preference) + Environment.NewLine, File.ReadAllText(path));
            }

            using (var reader = new FileStream(
                       path,
                       FileMode.Open,
                       FileAccess.Read,
                       FileShare.Read | FileShare.Delete))
            {
                store.Save(AppearancePreference.Light);
                Equal(AppearancePreference.Light, store.Load());
            }

            File.WriteAllText(path, "sepia\n", Utf8NoBom);
            Equal(AppearancePreference.System, store.Load());
            File.WriteAllBytes(path, [0xFF, 0xFE]);
            Equal(AppearancePreference.System, store.Load());
            File.WriteAllBytes(path, Enumerable.Repeat((byte)'x', AppearanceSettingsStore.MaximumSettingsBytes + 1).ToArray());
            Equal(AppearancePreference.System, store.Load());
            using (var oversized = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                oversized.SetLength(16 * 1024 * 1024);
            }
            Equal(AppearancePreference.System, store.Load());

            store.Save(AppearancePreference.Dark);
            Equal(AppearancePreference.Dark, store.Load());
            False(Directory.EnumerateFiles(Path.GetDirectoryName(path)!, "*.tmp").Any());
            False(Directory.EnumerateFiles(Path.GetDirectoryName(path)!, "*.bak").Any());
        });
    }

    private static void BalancedApplyPreservesToml()
    {
        WithProject(root =>
        {
            const string suffix = "# keep me\n[tools]\nenabled = true\n";
            WriteConfig(root, Utf8NoBom.GetBytes(suffix));
            var store = new ProjectConfigStore();
            var result = store.Apply(store.Load(root), ContextPolicy.Balanced400K);
            True(result.Changed);
            var text = ReadText(root);
            True(text.StartsWith(ManagedConfigEditor.MiniBeginMarker + "\n", StringComparison.Ordinal));
            True(text.EndsWith(suffix, StringComparison.Ordinal));
            True(text.Contains("model_context_window = 400000", StringComparison.Ordinal));
        });
    }

    private static void AutoRemovesManagedBlock()
    {
        WithProject(root =>
        {
            const string suffix = "[ui]\ncolor = \"blue\"\n";
            WriteConfig(root, Utf8NoBom.GetBytes(MiniBlock(128_000, 96_000, "\n") + suffix));
            var store = new ProjectConfigStore();
            var result = store.Apply(store.Load(root), ContextPolicy.Auto);
            True(result.Changed);
            Equal(suffix, ReadText(root));
            WriteConfig(root, Utf8NoBom.GetBytes(MiniBlock(128_000, 96_000, "\n")));
            store.Apply(store.Load(root), ContextPolicy.Auto);
            False(File.Exists(ConfigPath(root)));
        });
    }

    private static void AutoMissingCreatesNothing()
    {
        WithProject(root =>
        {
            var store = new ProjectConfigStore();
            var result = store.Apply(store.Load(root), ContextPolicy.Auto);
            False(result.Changed);
            False(Directory.Exists(Path.Combine(root, ".codex")));
        });
    }

    private static void ManualConflictRejected()
    {
        WithProject(root =>
        {
            const string original = "model_context_window = 123456\n";
            WriteConfig(root, Utf8NoBom.GetBytes(original));
            var store = new ProjectConfigStore();
            var snapshot = store.Load(root);
            False(snapshot.Document.CanWrite);
            Throws<ConfigConflictException>(() => store.Apply(snapshot, ContextPolicy.Balanced400K));
            Equal(original, ReadText(root));
        });
    }

    private static void ComplexConflictsRejected()
    {
        var cases = new[]
        {
            "[model_context_window]\nvalue = 1\n",
            "[[model_auto_compact_token_limit]]\nvalue = 1\n",
            "model_context_window.child = 1\n",
            "\"model_\\u0063ontext_window\" = 1\n",
        };
        foreach (var content in cases)
        {
            WithProject(root =>
            {
                WriteConfig(root, Utf8NoBom.GetBytes(content));
                var snapshot = new ProjectConfigStore().Load(root);
                False(snapshot.Document.CanWrite);
            });
        }
    }

    private static void NearLimitOutputRejected()
    {
        WithProject(root =>
        {
            var content = "#" + new string('x', (int)ProjectConfigStore.MaximumConfigBytes - 2) + "\n";
            var original = Utf8NoBom.GetBytes(content);
            Equal(ProjectConfigStore.MaximumConfigBytes, original.LongLength);
            WriteConfig(root, original);
            var store = new ProjectConfigStore();
            var snapshot = store.Load(root);
            Throws<UnsafeProjectException>(() => store.Apply(snapshot, ContextPolicy.Balanced400K));
            SequenceEqual(original, File.ReadAllBytes(ConfigPath(root)));
        });
    }
    private static void MalformedMarkersRejected()
    {
        WithProject(root =>
        {
            var original = ManagedConfigEditor.MiniBeginMarker + "\nmodel_context_window = 400000\n";
            WriteConfig(root, Utf8NoBom.GetBytes(original));
            var store = new ProjectConfigStore();
            var snapshot = store.Load(root);
            False(snapshot.Document.CanWrite);
            Throws<ConfigConflictException>(() => store.Apply(snapshot, ContextPolicy.Auto));
            Equal(original, ReadText(root));
        });
    }

    private static void LegacyBlockMigrates()
    {
        WithProject(root =>
        {
            const string suffix = "[other]\nvalue = 7\n";
            var legacy = string.Join("\n", ManagedConfigEditor.LegacyBeginMarker,
                "# requested_profile = \"balanced\"", "model_context_window = 400000",
                "model_auto_compact_token_limit = 320000", "model_auto_compact_token_limit_scope = \"total\"",
                ManagedConfigEditor.LegacyEndMarker, string.Empty);
            WriteConfig(root, Utf8NoBom.GetBytes(legacy + suffix));
            var store = new ProjectConfigStore();
            var snapshot = store.Load(root);
            Equal(ManagedBlockKind.LegacyPlugin, snapshot.Document.BlockKind);
            store.Apply(snapshot, ContextPolicy.OneMillion);
            var text = ReadText(root);
            True(text.StartsWith(ManagedConfigEditor.MiniBeginMarker, StringComparison.Ordinal));
            False(text.Contains(ManagedConfigEditor.LegacyBeginMarker, StringComparison.Ordinal));
            True(text.EndsWith(suffix, StringComparison.Ordinal));
        });
    }

    private static void LegacyBodyScopeSurvivesMigration()
    {
        WithProject(root =>
        {
            var legacy = string.Join("\n", ManagedConfigEditor.LegacyBeginMarker,
                "model_context_window = 400000", "model_auto_compact_token_limit = 320000",
                "model_auto_compact_token_limit_scope = \"body_after_prefix\"",
                ManagedConfigEditor.LegacyEndMarker, string.Empty);
            WriteConfig(root, Utf8NoBom.GetBytes(legacy));
            var store = new ProjectConfigStore();
            var snapshot = store.Load(root);
            Equal(ContextPolicy.BodyAfterPrefixScope, snapshot.Document.Scope);
            var preserved = ContextPolicy.Resolve(
                snapshot.Document.WindowTokens!.Value,
                snapshot.Document.CompactAtTokens!.Value,
                snapshot.Document.Scope!);
            Equal(ContextProfile.Custom, preserved.Profile);
            Equal(ContextPolicy.BodyAfterPrefixScope, preserved.Scope);
            store.Apply(snapshot, preserved);
            var migrated = store.Load(root);
            Equal(ManagedBlockKind.MiniV1, migrated.Document.BlockKind);
            Equal(ContextPolicy.BodyAfterPrefixScope, migrated.Document.Scope);
            True(ReadText(root).Contains(
                "model_auto_compact_token_limit_scope = \"body_after_prefix\"", StringComparison.Ordinal));
            Equal(ContextPolicy.TotalScope, ContextPolicy.Balanced400K.Scope);
        });
    }

    private static void StaleSnapshotRejected()
    {
        WithProject(root =>
        {
            WriteConfig(root, Utf8NoBom.GetBytes("# before\n"));
            var store = new ProjectConfigStore();
            var snapshot = store.Load(root);
            WriteConfig(root, Utf8NoBom.GetBytes("# after\n"));
            Throws<ConfigConflictException>(() => store.Apply(snapshot, ContextPolicy.Compact128K));
            Equal("# after\n", ReadText(root));
        });
    }

    private static void BomAndCrlfPreserved()
    {
        WithProject(root =>
        {
            var suffix = "# keep\r\n[table]\r\nvalue = 1\r\n";
            var content = Utf8NoBom.GetBytes(suffix);
            WriteConfig(root, [.. Utf8Bom, .. content]);
            var store = new ProjectConfigStore();
            var applied = store.Apply(store.Load(root), ContextPolicy.Compact128K);
            True(applied.Snapshot.HasUtf8Bom);
            var bytes = File.ReadAllBytes(ConfigPath(root));
            True(bytes.AsSpan().StartsWith(Utf8Bom));
            var text = Utf8NoBom.GetString(bytes.AsSpan(Utf8Bom.Length));
            True(text.Contains("\r\n", StringComparison.Ordinal));
            False(text.Replace("\r\n", string.Empty, StringComparison.Ordinal).Contains('\n'));
            store.Apply(store.Load(root), ContextPolicy.Auto);
            SequenceEqual([.. Utf8Bom, .. content], File.ReadAllBytes(ConfigPath(root)));
        });
    }

    private static void BomOnlyAutoNoOp()
    {
        WithProject(root =>
        {
            WriteConfig(root, Utf8Bom);
            var store = new ProjectConfigStore();
            var result = store.Apply(store.Load(root), ContextPolicy.Auto);
            False(result.Changed);
            SequenceEqual(Utf8Bom, File.ReadAllBytes(ConfigPath(root)));
        });
    }

    private static void ConcurrentExternalWritePreserved()
    {
        WithProject(root =>
        {
            WriteConfig(root, Utf8NoBom.GetBytes("# before\n"));
            var store = new ProjectConfigStore(path => File.WriteAllText(path, "# concurrent\n", Utf8NoBom));
            var snapshot = store.Load(root);
            Throws<ConfigConflictException>(() => store.Apply(snapshot, ContextPolicy.Balanced400K));
            Equal("# concurrent\n", ReadText(root));
        });
        WithProject(root =>
        {
            WriteConfig(root, Utf8NoBom.GetBytes(MiniBlock(400_000, 320_000, "\n") + "# suffix\n"));
            var store = new ProjectConfigStore(path => File.WriteAllText(path, "# concurrent Auto\n", Utf8NoBom));
            var snapshot = store.Load(root);
            Throws<ConfigConflictException>(() => store.Apply(snapshot, ContextPolicy.Auto));
            Equal("# concurrent Auto\n", ReadText(root));
        });
        WithProject(root =>
        {
            WriteConfig(root, Utf8NoBom.GetBytes("# before delete\n"));
            var store = new ProjectConfigStore(File.Delete);
            var snapshot = store.Load(root);
            Throws<ConfigConflictException>(() => store.Apply(snapshot, ContextPolicy.Balanced400K));
            False(File.Exists(ConfigPath(root)));
        });
        WithProject(root =>
        {
            var store = new ProjectConfigStore(path => File.WriteAllText(path, "# externally created\n", Utf8NoBom));
            var snapshot = store.Load(root);
            Throws<ConfigConflictException>(() => store.Apply(snapshot, ContextPolicy.Balanced400K));
            Equal("# externally created\n", ReadText(root));
        });
    }
    private static void OutOfRangeLegacyCanBeRemoved()
    {
        WithProject(root =>
        {
            const string suffix = "[other]\nvalue = 9\n";
            var legacy = string.Join("\n", ManagedConfigEditor.LegacyBeginMarker,
                "# requested_profile = \"custom\"", "# resolved_model = \"custom-provider\"",
                "# resolved_capacity = \"unknown\"", "model_context_window = 2000000",
                "model_auto_compact_token_limit = 1500000",
                "model_auto_compact_token_limit_scope = \"body_after_prefix\"",
                ManagedConfigEditor.LegacyEndMarker, string.Empty);
            WriteConfig(root, Utf8NoBom.GetBytes(legacy + suffix));
            var store = new ProjectConfigStore();
            var snapshot = store.Load(root);
            True(snapshot.Document.CanWrite);
            Equal(ManagedBlockKind.LegacyPlugin, snapshot.Document.BlockKind);
            store.Apply(snapshot, ContextPolicy.Auto);
            Equal(suffix, ReadText(root));
        });
    }
    private static void ActiveLockRejected()
    {
        WithProject(root =>
        {
            WriteConfig(root, Utf8NoBom.GetBytes("# safe\n"));
            var store = new ProjectConfigStore();
            var snapshot = store.Load(root);
            var lockPath = Path.Combine(root, ".codex", ".context-mini.lock");
            using var held = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            Throws<ConfigConflictException>(() => store.Apply(snapshot, ContextPolicy.Balanced400K));
            Equal("# safe\n", ReadText(root));
        });
    }

    private static void OversizedConfigRejected()
    {
        WithProject(root =>
        {
            WriteConfig(root, Enumerable.Repeat((byte)'x', (int)ProjectConfigStore.MaximumConfigBytes + 1).ToArray());
            Throws<UnsafeProjectException>(() => new ProjectConfigStore().Load(root));
        });
    }

    private static void ConfigReadStopsAtBoundedLimit()
    {
        WithProject(root =>
        {
            WriteConfig(root, Utf8NoBom.GetBytes("# exists\n"));
            var stream = new OversizedNonSeekableStream(ProjectConfigStore.MaximumConfigBytes + 128);
            var store = new ProjectConfigStore(null, _ => stream);
            Throws<UnsafeProjectException>(() => store.Load(root));
            Equal(ProjectConfigStore.MaximumConfigBytes + 1, stream.BytesRead);
        });
    }

    private static void InvalidUtf8Rejected()
    {
        WithProject(root =>
        {
            WriteConfig(root, [0xFF, 0xFE, 0xFF]);
            Throws<UnsafeProjectException>(() => new ProjectConfigStore().Load(root));
        });
    }

    private static void UnsafePathShapesRejected()
    {
        WithProject(root =>
        {
            File.WriteAllText(Path.Combine(root, ".codex"), "not a directory");
            Throws<UnsafeProjectException>(() => new ProjectConfigStore().Load(root));
        });
        WithProject(root =>
        {
            Directory.CreateDirectory(Path.Combine(root, ".codex", "config.toml"));
            Throws<UnsafeProjectException>(() => new ProjectConfigStore().Load(root));
        });
    }
    private static void FilesystemRootRejected() =>
        Throws<UnsafeProjectException>(() => WorkspaceValidator.Normalize(Path.GetPathRoot(Path.GetTempPath())!));

    private static void MappedNetworkDriveRejected()
    {
        WithProject(root => Throws<UnsafeProjectException>(() =>
            WorkspaceValidator.Normalize(root, _ => DriveType.Network)));
    }

    private static void FileSystemIdentityAttributesRejected()
    {
        FileSystemIdentity.ValidateHandleAttributes(FileAttributes.Directory, directory: true, "directory");
        FileSystemIdentity.ValidateHandleAttributes(FileAttributes.Archive, directory: false, "file");
        Throws<IOException>(() => FileSystemIdentity.ValidateHandleAttributes(
            FileAttributes.Directory | FileAttributes.ReparsePoint,
            directory: true,
            "directory-link"));
        Throws<IOException>(() => FileSystemIdentity.ValidateHandleAttributes(
            FileAttributes.Archive,
            directory: true,
            "file-instead-of-directory"));
        Throws<IOException>(() => FileSystemIdentity.ValidateHandleAttributes(
            FileAttributes.Directory,
            directory: false,
            "directory-instead-of-file"));
    }

    private static void SameByteReplacementDetected()
    {
        WithProject(root =>
        {
            const string original = "# same bytes\n";
            WriteConfig(root, Utf8NoBom.GetBytes(original));
            var displacedPath = ConfigPath(root) + ".displaced";
            var store = new ProjectConfigStore(path =>
            {
                File.Move(path, displacedPath);
                File.WriteAllBytes(path, Utf8NoBom.GetBytes(original));
            });
            var snapshot = store.Load(root);
            Throws<ConfigConflictException>(() => store.Apply(snapshot, ContextPolicy.Balanced400K));
            Equal(original, ReadText(root));
            True(File.Exists(displacedPath));
        });
    }

    private static void MissingConfigDirectoryReplacementDetected()
    {
        WithProject(root =>
        {
            var codexDirectory = Directory.CreateDirectory(Path.Combine(root, ".codex")).FullName;
            var replacementDirectory = Directory.CreateDirectory(Path.Combine(root, ".codex-replacement")).FullName;
            var replacementVisible = false;
            var store = new ProjectConfigStore(
                _ => replacementVisible = true,
                null,
                (path, directory) =>
                {
                    if (replacementVisible && directory &&
                        string.Equals(path, codexDirectory, StringComparison.OrdinalIgnoreCase))
                    {
                        return FileSystemIdentity.Read(replacementDirectory, directory: true);
                    }
                    return FileSystemIdentity.Read(path, directory);
                });
            var snapshot = store.Load(root);

            Throws<ConfigConflictException>(() => store.Apply(snapshot, ContextPolicy.Balanced400K));
            False(File.Exists(ConfigPath(root)));
            False(File.Exists(Path.Combine(replacementDirectory, "config.toml")));
            True(replacementVisible);
        });
    }

    private static void UnexpectedLegacyContentRejected()
    {
        WithProject(root =>
        {
            var text = string.Join("\n", ManagedConfigEditor.LegacyBeginMarker, "model_context_window = 400000",
                "model_auto_compact_token_limit = 320000", "model_auto_compact_token_limit_scope = \"total\"",
                "unexpected = true", ManagedConfigEditor.LegacyEndMarker, string.Empty);
            WriteConfig(root, Utf8NoBom.GetBytes(text));
            False(new ProjectConfigStore().Load(root).Document.CanWrite);
        });
    }

    private static void ReapplyIsIdempotent()
    {
        WithProject(root =>
        {
            var store = new ProjectConfigStore();
            True(store.Apply(store.Load(root), ContextPolicy.Balanced400K).Changed);
            False(store.Apply(store.Load(root), ContextPolicy.Balanced400K).Changed);
        });
    }

    private static void AtomicWriteLeavesNoArtifacts()
    {
        WithProject(root =>
        {
            var store = new ProjectConfigStore();
            store.Apply(store.Load(root), ContextPolicy.OneMillion);
            var codex = Path.Combine(root, ".codex");
            False(Directory.EnumerateFiles(codex, "*.tmp").Any());
            False(Directory.EnumerateFiles(codex, "*.bak").Any());
        });
    }

    private static string MiniBlock(long window, long compact, string newLine) =>
        string.Join(newLine, ManagedConfigEditor.MiniBeginMarker, $"model_context_window = {window}",
            $"model_auto_compact_token_limit = {compact}", "model_auto_compact_token_limit_scope = \"total\"",
            ManagedConfigEditor.MiniEndMarker, string.Empty);

    private static string ConfigPath(string root) => Path.Combine(root, ".codex", "config.toml");
    private static void WriteConfig(string root, byte[] bytes) { Directory.CreateDirectory(Path.Combine(root, ".codex")); File.WriteAllBytes(ConfigPath(root), bytes); }
    private static string ReadText(string root) { var bytes = File.ReadAllBytes(ConfigPath(root)); var payload = bytes.AsSpan().StartsWith(Utf8Bom) ? bytes.AsSpan(Utf8Bom.Length) : bytes.AsSpan(); return Utf8NoBom.GetString(payload); }

    private static void WithProject(Action<string> action)
    {
        var root = Directory.CreateTempSubdirectory("context-mini-tests-").FullName;
        try { action(root); }
        finally { TryDelete(root); }
    }

    private static void TryDelete(string root)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try { if (Directory.Exists(root)) Directory.Delete(root, true); return; }
            catch (IOException) when (attempt < 4) { Thread.Sleep(50); }
        }
    }

    private static void True(bool value) { if (!value) throw new InvalidOperationException("Expected true."); }
    private static void False(bool value) => True(!value);
    private static void Equal<T>(T expected, T actual) { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"Expected '{expected}', got '{actual}'."); }
    private static void SequenceEqual(byte[] expected, byte[] actual) { if (!expected.AsSpan().SequenceEqual(actual)) throw new InvalidOperationException("Byte sequences differ."); }
    private static void Throws<TException>(Action action) where TException : Exception
    {
        try { action(); }
        catch (TException) { return; }
        throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
    }

    private sealed class OversizedNonSeekableStream(long bytesAvailable) : Stream
    {
        private long _remaining = bytesAvailable;
        public long BytesRead { get; private set; }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count)
        {
            var read = (int)Math.Min(_remaining, count);
            Array.Fill(buffer, (byte)'x', offset, read);
            _remaining -= read;
            BytesRead += read;
            return read;
        }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
