using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using ContextMini.Core;
using Microsoft.Win32;

namespace ContextMini;

public partial class MainWindow : Window
{
    private static readonly Brush SelectedPresetBrush = new SolidColorBrush(Color.FromRgb(23, 105, 224));
    private static readonly Brush SelectedPresetTextBrush = Brushes.White;
    private static readonly Brush NormalPresetBrush = Brushes.White;
    private static readonly Brush NormalPresetTextBrush = new SolidColorBrush(Color.FromRgb(38, 52, 69));

    private readonly ProjectConfigStore _store = new();
    private readonly DispatcherTimer _monitor;
    private readonly string _initialProject;
    private ConfigSnapshot? _snapshot;
    private ContextPlan _draft = ContextPolicy.Auto;
    private string? _projectRoot;
    private bool _updatingUi;
    private bool _dirty;
    private bool _externalConflict;
    private bool _monitorBusy;

    public MainWindow(string initialProject)
    {
        _initialProject = initialProject;
        InitializeComponent();
        _monitor = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromMilliseconds(1500),
        };
        _monitor.Tick += Monitor_Tick;
        Loaded += MainWindow_Loaded;
        Closed += (_, _) => _monitor.Stop();
    }

    private void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        LoadProject(_initialProject);
        _monitor.Start();
    }

    private void LoadProject(string projectRoot)
    {
        try
        {
            var snapshot = _store.Load(projectRoot);
            _projectRoot = snapshot.ProjectRoot;
            _snapshot = snapshot;
            _externalConflict = false;
            ApplySnapshotToDraft(snapshot);
            StatusText.Text = snapshot.Document.Warning ?? "已从磁盘读取配置。监控间隔：1.5 秒。";
        }
        catch (Exception exception)
        {
            _snapshot = null;
            _projectRoot = null;
            _dirty = false;
            _externalConflict = false;
            _updatingUi = true;
            _draft = ContextPolicy.Auto;
            WindowSlider.Value = ContextPolicy.Balanced400K.WindowTokens!.Value;
            UpdateDraftText();
            UpdatePresetButtons();
            _updatingUi = false;
            ProjectNameText.Text = "未选择可用项目";
            ProjectPathText.Text = projectRoot;
            DiskStatusText.Text = "无法读取项目";
            StatusText.Text = exception.Message;
            WarningText.Text = "请选择一个存在、可信且不经过符号链接的本地项目目录。";
            WarningBorder.Visibility = Visibility.Visible;
            ApplyButton.IsEnabled = false;
        }
    }

    private void ApplySnapshotToDraft(ConfigSnapshot snapshot)
    {
        _updatingUi = true;
        try
        {
            _draft = ResolveSnapshotPlan(snapshot);
            WindowSlider.Value = _draft.WindowTokens ?? ContextPolicy.Balanced400K.WindowTokens!.Value;
            _dirty = snapshot.Document.BlockKind == ManagedBlockKind.LegacyPlugin;
            UpdateProjectText(snapshot);
            UpdateDraftText();
            UpdateDiskStatus(snapshot);
            UpdatePresetButtons();
            UpdateWarning(snapshot);
            UpdateApplyState();
        }
        finally
        {
            _updatingUi = false;
        }
    }

    private static ContextPlan ResolveSnapshotPlan(ConfigSnapshot snapshot)
    {
        if (!snapshot.ManagedBlockPresent) return ContextPolicy.Auto;
        try
        {
            return ContextPolicy.Resolve(
                snapshot.Document.WindowTokens!.Value,
                snapshot.Document.CompactAtTokens!.Value,
                "total");
        }
        catch (ArgumentException) when (snapshot.Document.BlockKind == ManagedBlockKind.LegacyPlugin)
        {
            return ContextPolicy.Auto;
        }
    }

    private void UpdateProjectText(ConfigSnapshot snapshot)
    {
        ProjectNameText.Text = new DirectoryInfo(snapshot.ProjectRoot).Name;
        ProjectPathText.Text = snapshot.ProjectRoot;
        ProjectPathText.ToolTip = snapshot.ProjectRoot;
    }

    private void UpdateDraftText()
    {
        if (_draft.IsAuto)
        {
            WindowValueText.Text = "Auto";
            CompactValueText.Text = "跟随其余配置";
        }
        else
        {
            WindowValueText.Text = _draft.WindowTokens!.Value.ToString("N0", CultureInfo.CurrentCulture);
            CompactValueText.Text = _draft.CompactAtTokens!.Value.ToString("N0", CultureInfo.CurrentCulture);
        }
    }

    private void UpdateDiskStatus(ConfigSnapshot snapshot)
    {
        if (!snapshot.Exists)
        {
            DiskStatusText.Text = "config.toml 不存在；当前等同 Auto。";
        }
        else if (!snapshot.Document.CanWrite)
        {
            DiskStatusText.Text = "检测到冲突或损坏标记；为安全起见保持只读。";
        }
        else if (!snapshot.ManagedBlockPresent)
        {
            DiskStatusText.Text = "未配置 Context Mini 覆盖（Auto）。";
        }
        else
        {
            var source = snapshot.Document.BlockKind == ManagedBlockKind.LegacyPlugin ? "旧插件块" : "Context Mini 块";
            DiskStatusText.Text = $"{source}：窗口 {snapshot.Document.WindowTokens:N0}，压缩 {snapshot.Document.CompactAtTokens:N0}。";
        }
    }

    private void UpdateWarning(ConfigSnapshot snapshot)
    {
        var warning = snapshot.Document.Warning;
        if (string.IsNullOrWhiteSpace(warning))
        {
            WarningBorder.Visibility = Visibility.Collapsed;
            WarningText.Text = string.Empty;
        }
        else
        {
            WarningBorder.Visibility = Visibility.Visible;
            WarningText.Text = warning;
        }
    }

    private void SetDraft(ContextPlan plan)
    {
        _updatingUi = true;
        try
        {
            _draft = plan;
            if (!plan.IsAuto) WindowSlider.Value = plan.WindowTokens!.Value;
            UpdateDraftText();
            UpdatePresetButtons();
            RecalculateDirty();
        }
        finally
        {
            _updatingUi = false;
        }
    }

    private void RecalculateDirty()
    {
        _dirty = _snapshot is not null && !MatchesDisk(_draft, _snapshot);
        if (_dirty && !_externalConflict) StatusText.Text = "草稿尚未应用。";
        UpdateApplyState();
    }

    private static bool MatchesDisk(ContextPlan plan, ConfigSnapshot snapshot)
    {
        if (snapshot.Document.BlockKind == ManagedBlockKind.LegacyPlugin) return false;
        if (plan.IsAuto) return !snapshot.ManagedBlockPresent;
        return snapshot.ManagedBlockPresent &&
               snapshot.Document.WindowTokens == plan.WindowTokens &&
               snapshot.Document.CompactAtTokens == plan.CompactAtTokens &&
               string.Equals(snapshot.Document.Scope, plan.Scope, StringComparison.Ordinal);
    }

    private void UpdatePresetButtons()
    {
        SetPresetState(AutoButton, _draft.Profile == ContextProfile.Auto);
        SetPresetState(CompactButton, _draft.Profile == ContextProfile.Compact128K);
        SetPresetState(BalancedButton, _draft.Profile == ContextProfile.Balanced400K);
        SetPresetState(OneMillionButton, _draft.Profile == ContextProfile.OneMillion);
    }

    private static void SetPresetState(Button button, bool selected)
    {
        button.Background = selected ? SelectedPresetBrush : NormalPresetBrush;
        button.Foreground = selected ? SelectedPresetTextBrush : NormalPresetTextBrush;
    }

    private void UpdateApplyState()
    {
        ApplyButton.IsEnabled = _snapshot is not null &&
                                _snapshot.Document.CanWrite &&
                                _dirty &&
                                !_externalConflict;
    }

    private void WindowSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_updatingUi || !IsLoaded) return;
        var window = Math.Clamp(
            (long)Math.Round(e.NewValue, MidpointRounding.AwayFromZero),
            ContextPolicy.MinimumWindowTokens,
            ContextPolicy.MaximumWindowTokens);
        _draft = ContextPolicy.Custom(window);
        UpdateDraftText();
        UpdatePresetButtons();
        RecalculateDirty();
    }

    private void Auto_Click(object sender, RoutedEventArgs e) => SetDraft(ContextPolicy.Auto);
    private void Compact_Click(object sender, RoutedEventArgs e) => SetDraft(ContextPolicy.Compact128K);
    private void Balanced_Click(object sender, RoutedEventArgs e) => SetDraft(ContextPolicy.Balanced400K);
    private void OneMillion_Click(object sender, RoutedEventArgs e) => SetDraft(ContextPolicy.OneMillion);

    private void Reload_Click(object sender, RoutedEventArgs e)
    {
        if (_projectRoot is not null) LoadProject(_projectRoot);
    }

    private void SwitchProject_Click(object sender, RoutedEventArgs e)
    {
        if (_dirty && MessageBox.Show(this, "切换项目会放弃尚未应用的草稿。继续吗？", "Context Mini",
                MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
        {
            return;
        }

        var dialog = new OpenFolderDialog
        {
            Title = "选择 Codex 项目目录",
            Multiselect = false,
            InitialDirectory = _projectRoot ?? Environment.CurrentDirectory,
        };
        if (dialog.ShowDialog(this) == true) LoadProject(dialog.FolderName);
    }

    private void Apply_Click(object sender, RoutedEventArgs e)
    {
        if (_snapshot is null || !_dirty || _externalConflict) return;
        var profileText = _draft.IsAuto
            ? "Auto（移除 Context Mini/旧插件管理块）"
            : $"窗口 {_draft.WindowTokens:N0}，压缩 {_draft.CompactAtTokens:N0}";
        var confirmation = $"目标项目：{_snapshot.ProjectRoot}\n配置文件：{_snapshot.ConfigPath}\n计划：{profileText}\n\n确认写入？";
        if (MessageBox.Show(this, confirmation, "确认应用", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
        {
            return;
        }

        try
        {
            var result = _store.Apply(_snapshot, _draft);
            LoadProject(result.Snapshot.ProjectRoot);
            StatusText.Text = result.Changed
                ? "应用成功。请新建 Codex 任务或重启应用后验证生效情况。"
                : "磁盘内容已经与草稿一致。";
        }
        catch (Exception exception)
        {
            _externalConflict = exception is ConfigConflictException;
            StatusText.Text = exception.Message;
            UpdateApplyState();
            MessageBox.Show(this, exception.Message, "无法应用", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void Monitor_Tick(object? sender, EventArgs e)
    {
        if (_monitorBusy || _snapshot is null || _projectRoot is null) return;
        _monitorBusy = true;
        try
        {
            var latest = _store.Load(_projectRoot);
            if (string.Equals(latest.Fingerprint, _snapshot.Fingerprint, StringComparison.Ordinal)) return;
            if (_dirty)
            {
                _externalConflict = true;
                StatusText.Text = "配置已被外部修改。重新加载后才能应用当前草稿。";
                UpdateApplyState();
            }
            else
            {
                _snapshot = latest;
                ApplySnapshotToDraft(latest);
                StatusText.Text = "检测到外部修改，界面已自动刷新。";
            }
        }
        catch (Exception exception)
        {
            _externalConflict = true;
            StatusText.Text = $"监控读取失败，应用已锁定：{exception.Message}";
            UpdateApplyState();
        }
        finally
        {
            _monitorBusy = false;
        }
    }
}
