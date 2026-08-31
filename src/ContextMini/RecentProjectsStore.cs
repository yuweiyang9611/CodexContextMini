using System.IO;
using System.Text;
using ContextMini.Core;

namespace ContextMini;

internal sealed class RecentProjectsStore
{
    public const int MaximumEntries = 8;
    public const long MaximumSettingsBytes = 64 * 1024;

    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public RecentProjectsStore(string settingsPath)
    {
        SettingsPath = Path.GetFullPath(settingsPath ?? throw new ArgumentNullException(nameof(settingsPath)));
    }

    public string SettingsPath { get; }

    public static RecentProjectsStore CreateDefault()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return new RecentProjectsStore(Path.Combine(appData, "ContextMini", "recent-projects.txt"));
    }

    public IReadOnlyList<string> Load()
    {
        if (!File.Exists(SettingsPath)) return [];
        RejectReparsePoint(SettingsPath, "Recent-project settings file");
        var fileLength = new FileInfo(SettingsPath).Length;
        if (fileLength > MaximumSettingsBytes)
        {
            throw new InvalidDataException("Recent-project settings exceed the safety limit.");
        }
        byte[] bytes;
        using (var stream = new FileStream(
                   SettingsPath,
                   FileMode.Open,
                   FileAccess.Read,
                   FileShare.Read | FileShare.Delete,
                   4096,
                   FileOptions.SequentialScan))
        {
            bytes = new byte[checked((int)MaximumSettingsBytes + 1)];
            var length = 0;
            while (length < bytes.Length)
            {
                var read = stream.Read(bytes, length, bytes.Length - length);
                if (read == 0) break;
                length += read;
            }
            if (length > MaximumSettingsBytes)
            {
                throw new InvalidDataException("Recent-project settings exceed the safety limit.");
            }
            Array.Resize(ref bytes, length);
        }

        var text = StrictUtf8.GetString(bytes);
        var entries = new List<string>();
        foreach (var line in text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            string fullPath;
            try
            {
                fullPath = Path.GetFullPath(line);
            }
            catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
            {
                continue;
            }
            if (!Path.IsPathFullyQualified(fullPath) || !Directory.Exists(fullPath)) continue;
            if (entries.Contains(fullPath, StringComparer.OrdinalIgnoreCase)) continue;
            entries.Add(fullPath);
            if (entries.Count == MaximumEntries) break;
        }
        return entries;
    }

    public void Remember(string projectRoot)
    {
        var normalized = WorkspaceValidator.Normalize(projectRoot);
        var entries = Load().Where(path =>
            !string.Equals(path, normalized, StringComparison.OrdinalIgnoreCase)).ToList();
        entries.Insert(0, normalized);
        if (entries.Count > MaximumEntries) entries.RemoveRange(MaximumEntries, entries.Count - MaximumEntries);
        Save(entries);
    }

    private void Save(IReadOnlyList<string> entries)
    {
        var directory = Path.GetDirectoryName(SettingsPath)
            ?? throw new InvalidOperationException("Recent-project settings require a parent directory.");
        Directory.CreateDirectory(directory);
        RejectReparsePoint(directory, "Recent-project settings directory");
        if (File.Exists(SettingsPath)) RejectReparsePoint(SettingsPath, "Recent-project settings file");

        var text = string.Join(Environment.NewLine, entries) + Environment.NewLine;
        var bytes = StrictUtf8.GetBytes(text);
        if (bytes.LongLength > MaximumSettingsBytes)
        {
            throw new InvalidDataException("Recent-project settings exceed the safety limit.");
        }

        var token = Guid.NewGuid().ToString("N");
        var temporary = Path.Combine(directory, $".{Path.GetFileName(SettingsPath)}.{token}.tmp");
        var backup = Path.Combine(directory, $".{Path.GetFileName(SettingsPath)}.{token}.bak");
        var committed = false;
        try
        {
            File.WriteAllBytes(temporary, bytes);
            for (var attempt = 0; attempt < 5; attempt++)
            {
                try
                {
                    if (File.Exists(SettingsPath))
                    {
                        RejectReparsePoint(SettingsPath, "Recent-project settings file");
                        File.Replace(temporary, SettingsPath, backup, ignoreMetadataErrors: false);
                    }
                    else
                    {
                        File.Move(temporary, SettingsPath);
                    }
                    committed = true;
                    break;
                }
                catch (Exception exception) when (
                    exception is IOException or UnauthorizedAccessException)
                {
                    if (attempt == 4 || !File.Exists(temporary) || File.Exists(backup)) throw;
                    Thread.Sleep(20 * (attempt + 1));
                }
            }
        }
        finally
        {
            DeleteBestEffort(temporary);
            if (committed) DeleteBestEffort(backup);
        }
    }

    private static void DeleteBestEffort(string path)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                if (!File.Exists(path)) return;
                File.Delete(path);
                return;
            }
            catch (Exception exception) when (
                exception is IOException or UnauthorizedAccessException)
            {
                if (attempt == 4) return;
                Thread.Sleep(20);
            }
        }
    }

    private static void RejectReparsePoint(string path, string label)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new IOException($"{label} must not be a reparse point: {path}");
        }
    }
}
