using System.IO;
using System.Security;
using System.Windows;
using ContextMini.Core;
using Microsoft.Win32;

namespace ContextMini;

internal sealed class AppearanceManager
{
    private const string PaletteMarkerKey = "ContextMiniPaletteMarker";
    private const string PersonalizeKey =
        @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    private const string AppsUseLightThemeValue = "AppsUseLightTheme";

    private readonly Application _application;
    private readonly AppearanceSettingsStore _settings;
    private readonly Func<bool?> _readSystemUsesDark;
    private readonly Func<bool> _readHighContrast;
    private AppearancePreference _persistedPreference;
    private PaletteKind? _paletteKind;
    private bool? _effectiveDark;

    internal AppearanceManager(
        Application application,
        AppearanceSettingsStore settings,
        Func<bool?>? readSystemUsesDark = null,
        Func<bool>? readHighContrast = null)
    {
        _application = application ?? throw new ArgumentNullException(nameof(application));
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _readSystemUsesDark = readSystemUsesDark ?? ReadWindowsUsesDark;
        _readHighContrast = readHighContrast ?? (() => SystemParameters.HighContrast);
        Preference = settings.Load();
        _persistedPreference = Preference;
        ApplyWpfThemeMode(Preference);
        ApplyPalette(Preference, force: true);
    }

    internal AppearancePreference Preference { get; private set; }

    internal (bool Saved, string? ErrorMessage) SetPreference(AppearancePreference preference)
    {
        if (!Enum.IsDefined(preference)) throw new ArgumentOutOfRangeException(nameof(preference));
        if (preference != Preference)
        {
            var previousPreference = Preference;
            try
            {
                ApplyWpfThemeMode(preference);
                ApplyPalette(preference, force: false);
                Preference = preference;
            }
            catch
            {
                try
                {
                    ApplyWpfThemeMode(previousPreference);
                    ApplyPalette(previousPreference, force: true);
                }
                catch (Exception rollbackException)
                {
                    System.Diagnostics.Debug.WriteLine($"Appearance rollback failed: {rollbackException}");
                }

                throw;
            }
        }

        if (_persistedPreference == preference) return (true, null);
        try
        {
            _settings.Save(preference);
            _persistedPreference = preference;
            return (true, null);
        }
        catch (Exception exception) when (IsSettingsWriteFailure(exception))
        {
            return (false, exception.Message);
        }
    }

    internal void RefreshSystemTheme()
    {
        ApplyPalette(Preference, force: _readHighContrast());
    }

    private void ApplyWpfThemeMode(AppearancePreference preference)
    {
#pragma warning disable WPF0001
        _application.ThemeMode = preference switch
        {
            AppearancePreference.System => ThemeMode.System,
            AppearancePreference.Light => ThemeMode.Light,
            AppearancePreference.Dark => ThemeMode.Dark,
            _ => throw new ArgumentOutOfRangeException(nameof(preference)),
        };
#pragma warning restore WPF0001
    }

    private void ApplyPalette(AppearancePreference preference, bool force)
    {
        var paletteKind = ResolvePaletteKind(preference, out var effectiveDark);
        if (!force && _paletteKind == paletteKind)
        {
            _effectiveDark = effectiveDark;
            return;
        }

        var palette = CreatePalette(paletteKind);
        var dictionaries = _application.Resources.MergedDictionaries;
        var currentIndex = -1;
        for (var index = 0; index < dictionaries.Count; index++)
        {
            if (!IsContextMiniPalette(dictionaries[index])) continue;
            currentIndex = index;
            break;
        }

        if (currentIndex >= 0)
        {
            dictionaries[currentIndex] = palette;
        }
        else
        {
            dictionaries.Add(palette);
        }

        _paletteKind = paletteKind;
        _effectiveDark = effectiveDark;
    }

    private PaletteKind ResolvePaletteKind(AppearancePreference preference, out bool effectiveDark)
    {
        if (_readHighContrast())
        {
            effectiveDark = _effectiveDark ?? false;
            return PaletteKind.HighContrast;
        }

        var systemUsesDark = preference == AppearancePreference.System ? _readSystemUsesDark() : null;
        effectiveDark = preference == AppearancePreference.System && systemUsesDark is null
            ? _effectiveDark ?? false
            : AppearancePreferenceCodec.ResolveDark(preference, systemUsesDark ?? false);
        return effectiveDark ? PaletteKind.Dark : PaletteKind.Light;
    }

    private static ResourceDictionary CreatePalette(PaletteKind paletteKind)
    {
        if (paletteKind == PaletteKind.HighContrast) return CreateHighContrastPalette();

        var palette = new ResourceDictionary
        {
            Source = new Uri($"pack://application:,,,/ContextMini;component/Themes/{paletteKind}.xaml", UriKind.Absolute),
        };
        palette[PaletteMarkerKey] = paletteKind.ToString();
        return palette;
    }

    private static ResourceDictionary CreateHighContrastPalette()
    {
        var palette = new ResourceDictionary
        {
            [PaletteMarkerKey] = PaletteKind.HighContrast.ToString(),
            ["WindowBackgroundBrush"] = SystemColors.WindowBrush,
            ["HeaderBackgroundBrush"] = SystemColors.WindowBrush,
            ["HeaderTextBrush"] = SystemColors.WindowTextBrush,
            ["HeaderSecondaryTextBrush"] = SystemColors.WindowTextBrush,
            ["HeaderControlBackgroundBrush"] = SystemColors.ControlBrush,
            ["HeaderControlHoverBackgroundBrush"] = SystemColors.HighlightBrush,
            ["HeaderControlBorderBrush"] = SystemColors.ControlTextBrush,
            ["HeaderControlTextBrush"] = SystemColors.ControlTextBrush,
            ["HeaderControlHoverTextBrush"] = SystemColors.HighlightTextBrush,
            ["HeaderSelectedBackgroundBrush"] = SystemColors.HighlightBrush,
            ["HeaderSelectedTextBrush"] = SystemColors.HighlightTextBrush,
            ["SurfaceBackgroundBrush"] = SystemColors.WindowBrush,
            ["SurfaceBorderBrush"] = SystemColors.WindowTextBrush,
            ["AlternateSurfaceBrush"] = SystemColors.WindowBrush,
            ["PrimaryTextBrush"] = SystemColors.WindowTextBrush,
            ["SecondaryTextBrush"] = SystemColors.WindowTextBrush,
            ["TertiaryTextBrush"] = SystemColors.WindowTextBrush,
            ["AccentTextBrush"] = SystemColors.HotTrackBrush,
            ["ControlBackgroundBrush"] = SystemColors.ControlBrush,
            ["ControlHoverBackgroundBrush"] = SystemColors.HighlightBrush,
            ["ControlPressedBackgroundBrush"] = SystemColors.HighlightBrush,
            ["ControlBorderBrush"] = SystemColors.ControlTextBrush,
            ["ControlTextBrush"] = SystemColors.ControlTextBrush,
            ["ControlHoverTextBrush"] = SystemColors.HighlightTextBrush,
            ["PrimaryActionBackgroundBrush"] = SystemColors.HighlightBrush,
            ["PrimaryActionHoverBackgroundBrush"] = SystemColors.HighlightBrush,
            ["PrimaryActionPressedBackgroundBrush"] = SystemColors.HighlightBrush,
            ["OnPrimaryActionTextBrush"] = SystemColors.HighlightTextBrush,
            ["SelectedControlBackgroundBrush"] = SystemColors.HighlightBrush,
            ["SelectedControlTextBrush"] = SystemColors.HighlightTextBrush,
            ["FocusBorderBrush"] = SystemColors.WindowTextBrush,
            ["WarningBackgroundBrush"] = SystemColors.WindowBrush,
            ["WarningBorderBrush"] = SystemColors.WindowTextBrush,
            ["WarningTextBrush"] = SystemColors.WindowTextBrush,
            ["FooterBackgroundBrush"] = SystemColors.WindowBrush,
            ["FooterBorderBrush"] = SystemColors.WindowTextBrush,
        };
        return palette;
    }

    private static bool IsContextMiniPalette(ResourceDictionary dictionary)
    {
        if (dictionary.Contains(PaletteMarkerKey)) return true;
        var source = dictionary.Source?.OriginalString.Replace('\\', '/');
        return source is not null &&
               (source.EndsWith("Themes/Light.xaml", StringComparison.OrdinalIgnoreCase) ||
                source.EndsWith("Themes/Dark.xaml", StringComparison.OrdinalIgnoreCase));
    }

    private static bool? ReadWindowsUsesDark()
    {
        try
        {
            return Registry.GetValue(PersonalizeKey, AppsUseLightThemeValue, null) switch
            {
                int value => value == 0,
                long value => value == 0,
                byte value => value == 0,
                _ => null,
            };
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SecurityException)
        {
            return null;
        }
    }

    private static bool IsSettingsWriteFailure(Exception exception) =>
        exception is IOException or UnauthorizedAccessException or SecurityException or NotSupportedException;

    private enum PaletteKind
    {
        Light,
        Dark,
        HighContrast,
    }
}
