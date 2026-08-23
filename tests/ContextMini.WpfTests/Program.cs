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
        });
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
