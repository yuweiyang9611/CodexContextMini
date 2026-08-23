using System.Security.Cryptography;
using System.Text;

namespace ContextMini.Core;

public sealed class ProjectConfigStore
{
    public const long MaximumConfigBytes = 2 * 1024 * 1024;

    private static readonly byte[] Utf8Bom = [0xEF, 0xBB, 0xBF];
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly UTF8Encoding Utf8NoBom = new(false);
    private readonly ManagedConfigEditor _editor = new();
    private readonly Action<string>? _beforeAtomicMutation;

    public ProjectConfigStore()
    {
    }

    internal ProjectConfigStore(Action<string> beforeAtomicMutation)
    {
        _beforeAtomicMutation = beforeAtomicMutation;
    }

    public ConfigSnapshot Load(string projectRoot)
    {
        var root = WorkspaceValidator.Normalize(projectRoot);
        var codexDirectory = Path.Combine(root, ".codex");
        var configPath = Path.Combine(codexDirectory, "config.toml");
        WorkspaceValidator.RejectReparsePoint(codexDirectory, ".codex directory");
        WorkspaceValidator.RejectReparsePoint(configPath, "config.toml");

        if (File.Exists(codexDirectory)) throw new UnsafeProjectException(".codex must be a directory.");
        if (Directory.Exists(configPath)) throw new UnsafeProjectException("config.toml must be a regular file.");

        if (!File.Exists(configPath))
        {
            var emptyDocument = _editor.Analyze(string.Empty);
            return new ConfigSnapshot(root, configPath, false, "missing", false, [], emptyDocument);
        }

        var info = new FileInfo(configPath);
        if (info.Length > MaximumConfigBytes)
        {
            throw new UnsafeProjectException($"config.toml exceeds the {MaximumConfigBytes:N0}-byte safety limit.");
        }
        var bytes = File.ReadAllBytes(configPath);
        var hasBom = bytes.AsSpan().StartsWith(Utf8Bom);
        var payload = hasBom ? bytes.AsSpan(Utf8Bom.Length) : bytes.AsSpan();
        string text;
        try
        {
            text = StrictUtf8.GetString(payload);
        }
        catch (DecoderFallbackException exception)
        {
            throw new UnsafeProjectException($"config.toml must be valid UTF-8: {exception.Message}");
        }
        return new ConfigSnapshot(root, configPath, true, Fingerprint(bytes), hasBom, bytes, _editor.Analyze(text));
    }

    public ApplyResult Apply(ConfigSnapshot expected, ContextPlan plan)
    {
        ArgumentNullException.ThrowIfNull(expected);
        ContextPolicy.Validate(plan);
        var root = WorkspaceValidator.Normalize(expected.ProjectRoot);
        if (!string.Equals(root, expected.ProjectRoot, StringComparison.OrdinalIgnoreCase))
        {
            throw new ConfigConflictException("The selected project changed before apply.");
        }

        var before = Load(root);
        EnsureExpected(before, expected);
        if (!before.Document.CanWrite)
        {
            throw new ConfigConflictException(before.Document.Warning ?? "config.toml is read-only for safety.");
        }
        if (plan.IsAuto && !before.ManagedBlockPresent)
        {
            return new ApplyResult(false, before);
        }

        var desiredText = _editor.Render(before.Document, plan);
        var desiredBytes = Encode(desiredText, before.HasUtf8Bom);
        EnsureOutputSize(desiredBytes);
        if (before.SourceBytes.AsSpan().SequenceEqual(desiredBytes))
        {
            return new ApplyResult(false, before);
        }
        if (!before.Exists && desiredBytes.Length == 0)
        {
            return new ApplyResult(false, before);
        }

        var codexDirectory = Path.GetDirectoryName(before.ConfigPath)!;
        Directory.CreateDirectory(codexDirectory);
        WorkspaceValidator.RejectReparsePoint(codexDirectory, ".codex directory");
        var lockPath = Path.Combine(codexDirectory, ".context-mini.lock");
        WorkspaceValidator.RejectReparsePoint(lockPath, "Context Mini lock");

        using var projectLock = AcquireLock(lockPath);
        var locked = Load(root);
        EnsureExpected(locked, expected);
        if (!locked.Document.CanWrite)
        {
            throw new ConfigConflictException(locked.Document.Warning ?? "config.toml became unsafe before apply.");
        }
        desiredText = _editor.Render(locked.Document, plan);
        desiredBytes = Encode(desiredText, locked.HasUtf8Bom);
        EnsureOutputSize(desiredBytes);
        if (locked.SourceBytes.AsSpan().SequenceEqual(desiredBytes))
        {
            return new ApplyResult(false, locked);
        }

        _beforeAtomicMutation?.Invoke(locked.ConfigPath);
        if (desiredBytes.Length == 0)
        {
            AtomicDelete(locked.ConfigPath, locked.SourceBytes);
        }
        else
        {
            AtomicWrite(locked.ConfigPath, desiredBytes, locked.SourceBytes, locked.Exists);
        }

        var after = Load(root);
        if (desiredBytes.Length == 0)
        {
            if (after.Exists) throw new IOException("Post-apply verification expected config.toml to be absent.");
        }
        else if (!after.SourceBytes.AsSpan().SequenceEqual(desiredBytes))
        {
            throw new IOException("Post-apply verification found unexpected config.toml bytes.");
        }
        return new ApplyResult(true, after);
    }

    private static void EnsureOutputSize(byte[] bytes)
    {
        if (bytes.LongLength > MaximumConfigBytes)
        {
            throw new UnsafeProjectException($"Applying this profile would exceed the {MaximumConfigBytes:N0}-byte config.toml safety limit.");
        }
    }

    private static byte[] Encode(string text, bool preserveBom)
    {
        if (text.Length == 0) return [];
        var content = Utf8NoBom.GetBytes(text);
        if (!preserveBom) return content;
        var result = new byte[Utf8Bom.Length + content.Length];
        Utf8Bom.CopyTo(result, 0);
        content.CopyTo(result, Utf8Bom.Length);
        return result;
    }

    private static void EnsureExpected(ConfigSnapshot actual, ConfigSnapshot expected)
    {
        if (!string.Equals(actual.ConfigPath, expected.ConfigPath, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(actual.Fingerprint, expected.Fingerprint, StringComparison.Ordinal))
        {
            throw new ConfigConflictException("config.toml changed outside Context Mini. Reload before applying.");
        }
    }

    private static FileStream AcquireLock(string lockPath)
    {
        Exception? lastError = null;
        for (var attempt = 0; attempt < 10; attempt++)
        {
            try
            {
                return new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, 1, FileOptions.WriteThrough);
            }
            catch (IOException exception)
            {
                lastError = exception;
                Thread.Sleep(50);
            }
        }
        throw new ConfigConflictException($"Another Context Mini instance is writing this project: {lastError?.Message}");
    }

    private static void AtomicWrite(string configPath, byte[] desiredBytes, byte[] expectedBytes, bool expectedExists)
    {
        var directory = Path.GetDirectoryName(configPath)!;
        var token = Guid.NewGuid().ToString("N");
        var tempPath = Path.Combine(directory, $".context-mini.{token}.tmp");
        var backupPath = Path.Combine(directory, $".context-mini.{token}.bak");
        var rollbackPath = Path.Combine(directory, $".context-mini.{token}.rollback");
        if (File.Exists(configPath) != expectedExists)
        {
            throw new ConfigConflictException("config.toml existence changed immediately before atomic write.");
        }
        var mutationCommitted = false;
        try
        {
            using (var stream = new FileStream(tempPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                stream.Write(desiredBytes);
                stream.Flush(true);
            }

            if (expectedExists)
            {
                File.Replace(tempPath, configPath, backupPath, true);
                mutationCommitted = true;
                if (!File.ReadAllBytes(backupPath).AsSpan().SequenceEqual(expectedBytes))
                {
                    throw new ConfigConflictException("config.toml changed during atomic replace; the external version will be restored.");
                }
            }
            else
            {
                File.Move(tempPath, configPath);
                mutationCommitted = true;
            }

            if (!File.Exists(configPath) || !File.ReadAllBytes(configPath).AsSpan().SequenceEqual(desiredBytes))
            {
                throw new ConfigConflictException("config.toml changed during post-write verification.");
            }
            DeleteIfPresent(backupPath);
        }
        catch (Exception writeError)
        {
            Exception? restoreError = null;
            try
            {
                if (mutationCommitted && File.Exists(backupPath))
                {
                    var backupBytes = File.ReadAllBytes(backupPath);
                    if (File.Exists(configPath) && File.ReadAllBytes(configPath).AsSpan().SequenceEqual(desiredBytes))
                    {
                        File.Replace(backupPath, configPath, rollbackPath, true);
                        DeleteIfPresent(rollbackPath);
                    }
                    else
                    {
                        restoreError = new ConfigConflictException($"config.toml changed again; recovery backup was retained at {backupPath} ({backupBytes.Length:N0} bytes).");
                    }
                }
                else if (mutationCommitted && !expectedExists && File.Exists(configPath))
                {
                    if (File.ReadAllBytes(configPath).AsSpan().SequenceEqual(desiredBytes))
                    {
                        File.Delete(configPath);
                    }
                    else
                    {
                        restoreError = new ConfigConflictException("A new external config.toml appeared during rollback and was preserved.");
                    }
                }
                else if (!mutationCommitted && File.Exists(backupPath))
                {
                    restoreError = new ConfigConflictException($"Atomic replacement did not complete; an unexpected backup was retained at {backupPath}.");
                }
            }
            catch (Exception exception)
            {
                restoreError = exception;
            }
            finally
            {
                DeleteIfPresent(tempPath);
                DeleteIfPresent(rollbackPath);
                if (restoreError is null) DeleteIfPresent(backupPath);
            }
            if (restoreError is not null)
            {
                throw new AggregateException($"Atomic write failed and rollback could not safely complete; inspect {backupPath}.", writeError, restoreError);
            }
            throw;
        }
        finally
        {
            DeleteIfPresent(tempPath);
        }
    }

    private static void AtomicDelete(string configPath, byte[] expectedBytes)
    {
        if (!File.Exists(configPath))
        {
            throw new ConfigConflictException("config.toml was deleted externally immediately before Auto.");
        }
        var directory = Path.GetDirectoryName(configPath)!;
        var backupPath = Path.Combine(directory, $".context-mini.{Guid.NewGuid():N}.bak");
        try
        {
            File.Move(configPath, backupPath);
            if (!File.ReadAllBytes(backupPath).AsSpan().SequenceEqual(expectedBytes))
            {
                if (!File.Exists(configPath)) File.Move(backupPath, configPath);
                throw new ConfigConflictException("config.toml changed immediately before Auto; the external version was preserved.");
            }
            if (File.Exists(configPath))
            {
                throw new ConfigConflictException($"A new external config.toml appeared during Auto; it and backup {backupPath} were preserved.");
            }
            File.Delete(backupPath);
        }
        catch
        {
            if (File.Exists(backupPath) && !File.Exists(configPath)) File.Move(backupPath, configPath);
            throw;
        }
    }
    private static void DeleteIfPresent(string path)
    {
        if (File.Exists(path)) File.Delete(path);
    }

    private static string Fingerprint(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
}
