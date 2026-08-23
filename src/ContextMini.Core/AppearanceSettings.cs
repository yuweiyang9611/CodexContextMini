using System.Security;
using System.Text;

namespace ContextMini.Core;

public enum AppearancePreference
{
    System,
    Light,
    Dark,
}

public static class AppearancePreferenceCodec
{
    public static AppearancePreference ParseOrSystem(string? value) =>
        TryParse(value, out var preference) ? preference : AppearancePreference.System;

    public static bool TryParse(string? value, out AppearancePreference preference)
    {
        preference = AppearancePreference.System;
        if (string.IsNullOrWhiteSpace(value)) return false;

        switch (value.Trim().ToLowerInvariant())
        {
            case "system":
                return true;
            case "light":
                preference = AppearancePreference.Light;
                return true;
            case "dark":
                preference = AppearancePreference.Dark;
                return true;
            default:
                return false;
        }
    }

    public static string Format(AppearancePreference preference) => preference switch
    {
        AppearancePreference.System => "system",
        AppearancePreference.Light => "light",
        AppearancePreference.Dark => "dark",
        _ => throw new ArgumentOutOfRangeException(nameof(preference)),
    };

    public static bool ResolveDark(AppearancePreference preference, bool systemUsesDark) => preference switch
    {
        AppearancePreference.System => systemUsesDark,
        AppearancePreference.Light => false,
        AppearancePreference.Dark => true,
        _ => throw new ArgumentOutOfRangeException(nameof(preference)),
    };
}

public sealed class AppearanceSettingsStore
{
    public const int MaximumSettingsBytes = 128;

    private static readonly byte[] Utf8Bom = [0xEF, 0xBB, 0xBF];
    private static readonly UTF8Encoding Utf8Strict = new(false, true);

    public AppearanceSettingsStore(string settingsPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(settingsPath);
        SettingsPath = Path.GetFullPath(settingsPath);
    }

    public string SettingsPath { get; }

    public static AppearanceSettingsStore CreateDefault()
    {
        var localData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localData))
        {
            throw new InvalidOperationException("Windows did not provide a LocalApplicationData directory.");
        }

        return new AppearanceSettingsStore(Path.Combine(localData, "ContextMini", "appearance.txt"));
    }

    public AppearancePreference Load()
    {
        try
        {
            if (!File.Exists(SettingsPath)) return AppearancePreference.System;
            using var stream = new FileStream(SettingsPath, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (stream.Length > MaximumSettingsBytes) return AppearancePreference.System;

            var bytes = new byte[MaximumSettingsBytes + 1];
            var length = 0;
            while (length < bytes.Length)
            {
                var read = stream.Read(bytes, length, bytes.Length - length);
                if (read == 0) break;
                length += read;
            }
            if (length > MaximumSettingsBytes) return AppearancePreference.System;

            var offset = bytes.AsSpan(0, length).StartsWith(Utf8Bom) ? Utf8Bom.Length : 0;
            return AppearancePreferenceCodec.ParseOrSystem(Utf8Strict.GetString(bytes, offset, length - offset));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or DecoderFallbackException or SecurityException)
        {
            return AppearancePreference.System;
        }
    }

    public void Save(AppearancePreference preference)
    {
        var payload = AppearancePreferenceCodec.Format(preference) + Environment.NewLine;
        var directory = Path.GetDirectoryName(SettingsPath)
            ?? throw new InvalidOperationException("The appearance settings path has no parent directory.");
        Directory.CreateDirectory(directory);

        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(SettingsPath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporaryPath, payload, Utf8Strict);
            File.Move(temporaryPath, SettingsPath, true);
        }
        finally
        {
            try
            {
                if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SecurityException)
            {
                // A failed preference save must not hide the original error.
            }
        }
    }
}
