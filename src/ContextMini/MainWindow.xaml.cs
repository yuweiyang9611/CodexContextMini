using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Threading;
using ContextMini.Core;
using Microsoft.Win32;

namespace ContextMini;

public partial class MainWindow : Window
{
    private const int WmSettingChange = 0x001A;
    private const int WmSystemColorChange = 0x0015;
    private const int WmThemeChanged = 0x031A;

    private readonly AppearanceManager _appearance;
    private readonly ProjectSessionController _session;
    private readonly RecentProjectsStore _recentProjects;
    private readonly DispatcherTimer _monitor;
    private readonly string _initialProject;
    private HwndSource? _windowSource;
    private HwndSourceHook? _themeMessageHook;
    private bool _updatingUi;
    private bool _updatingAppearance;
    private bool _themeRefreshQueued;

    internal MainWindow(string initialProject, AppearanceManager appearance)
        : this(initialProject, appearance, RecentProjectsStore.CreateDefault())
    {
    }

    internal MainWindow(
        string initialProject,
        AppearanceManager appearance,
        RecentProjectsStore recentProjects)
        : this(
            initialProject,
            appearance,
            recentProjects,
            new ProjectSessionController(new ProjectSessionFileStore()))
    {
    }

    internal MainWindow(
        string initialProject,
        AppearanceManager appearance,
        RecentProjectsStore recentProjects,
        ProjectSessionController session)
    {
        _initialProject = initialProject;
        _appearance = appearance ?? throw new ArgumentNullException(nameof(appearance));
        _recentProjects = recentProjects ?? throw new ArgumentNullException(nameof(recentProjects));
        _session = session ?? throw new ArgumentNullException(nameof(session));
        _updatingAppearance = true;
        InitializeComponent();
        SetDraftEditingEnabled(false);
        UpdateAppearanceSelector();
        _updatingAppearance = false;
        _monitor = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromMilliseconds(1500),
        };
        _monitor.Tick += Monitor_Tick;
        Loaded += MainWindow_Loaded;
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        _windowSource = HwndSource.FromHwnd(new WindowInteropHelper(this).Handle);
        _themeMessageHook = ThemeWindowProc;
        _windowSource?.AddHook(_themeMessageHook);
        QueueThemeRefresh();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_session.CanClose)
        {
            e.Cancel = true;
            MessageBox.Show(
                this,
                "正在写入配置，请等待操作完成后再关闭窗口。",
                "Context Mini",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            return;
        }
        if ((_session.IsDirty || !_session.IsInputValid) &&
            MessageBox.Show(
                this,
                "关闭窗口会放弃尚未应用的草稿。继续吗？",
                "Context Mini",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning) != MessageBoxResult.Yes)
        {
            e.Cancel = true;
            return;
        }
        base.OnClosing(e);
    }

    protected override void OnClosed(EventArgs e)
    {
        _session.Close();
        _monitor.Stop();
        if (_windowSource is not null && _themeMessageHook is not null)
        {
            _windowSource.RemoveHook(_themeMessageHook);
        }

        _themeMessageHook = null;
        _windowSource = null;
        base.OnClosed(e);
    }

    private IntPtr ThemeWindowProc(
        IntPtr hwnd,
        int message,
        IntPtr wParam,
        IntPtr lParam,
        ref bool handled)
    {
        if (message is WmSettingChange or WmSystemColorChange or WmThemeChanged) QueueThemeRefresh();
        return IntPtr.Zero;
    }

    private void QueueThemeRefresh()
    {
        if (_session.IsClosed || _themeRefreshQueued) return;
        _themeRefreshQueued = true;
        _ = Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() =>
        {
            _themeRefreshQueued = false;
            if (_session.IsClosed) return;
            try
            {
                _appearance.RefreshSystemTheme();
            }
            catch (Exception exception)
            {
                Debug.WriteLine($"System appearance refresh failed: {exception}");
            }
        }));
    }

    private void UpdateAppearanceSelector()
    {
        var wasUpdating = _updatingAppearance;
        _updatingAppearance = true;
        try
        {
            SystemAppearanceButton.IsChecked = _appearance.Preference == AppearancePreference.System;
            LightAppearanceButton.IsChecked = _appearance.Preference == AppearancePreference.Light;
            DarkAppearanceButton.IsChecked = _appearance.Preference == AppearancePreference.Dark;
        }
        finally
        {
            _updatingAppearance = wasUpdating;
        }
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        RefreshRecentProjects();
        var loaded = false;
        if (string.IsNullOrWhiteSpace(_initialProject))
        {
            ShowUnavailableProject(
                string.Empty,
                new UnsafeProjectException("尚未选择项目。请选择一个本地 Codex 项目目录。"));
        }
        else
        {
            loaded = await LoadProjectAsync(_initialProject, preserveDraft: false, resetOnFailure: true);
        }
        if (!loaded && !_session.IsClosed)
        {
            await PromptForProjectAsync();
        }
        if (!_session.IsClosed) _monitor.Start();
    }

    private async Task<bool> LoadProjectAsync(
        string projectRoot,
        bool preserveDraft,
        bool resetOnFailure)
    {
        var load = _session.LoadProjectAsync(projectRoot, preserveDraft);
        SetDraftEditingEnabled(false);
        UpdateConflictActions();
        UpdateApplyState();
        try
        {
            var outcome = await load;
            if (_session.IsClosed || outcome.Superseded || outcome.Kind == SessionLoadKind.Skipped) return false;
            if (!outcome.Succeeded || outcome.Snapshot is null)
            {
                var exception = outcome.Error ?? new IOException("The project could not be loaded.");
                if (resetOnFailure)
                {
                    ShowUnavailableProject(projectRoot, exception);
                }
                else if (PathsReferToSameProject(projectRoot, outcome.PreviousProjectRoot))
                {
                    _session.RequireReload();
                    ShowReloadRequired(
                        $"无法重新读取当前项目：{exception.Message}",
                        "当前磁盘基线无法确认；草稿已保留，请稍后重新读取。");
                    MessageBox.Show(
                        this,
                        exception.Message,
                        "无法重新读取项目",
                        MessageBoxButton.OK,
                        MessageBoxImage.Error);
                }
                else
                {
                    StatusText.Text =
                        $"无法打开所选项目，仍保留当前项目和草稿：{exception.Message}";
                    MessageBox.Show(
                        this,
                        exception.Message,
                        "无法打开所选项目",
                        MessageBoxButton.OK,
                        MessageBoxImage.Error);
                }
                return false;
            }

            var snapshot = outcome.Snapshot;
            ClearExternalConflictVisual();
            if (preserveDraft)
            {
                UpdateProjectText(snapshot);
                UpdateDiskStatus(snapshot);
                UpdateWarning(snapshot);
                RecalculateDirty();
            }
            else
            {
                ApplySessionSnapshotToUi(snapshot);
            }

            RememberProject(snapshot.ProjectRoot);
            StatusText.Text = snapshot.Document.Warning ??
                (preserveDraft
                    ? "已重新读取磁盘配置，并保留当前草稿。"
                    : "已从磁盘读取配置。监控间隔：1.5 秒（后台读取）。");
            return true;
        }
        finally
        {
            if (!_session.IsClosed)
                SetDraftEditingEnabled(!_session.IsApplyBusy && _session.Snapshot is not null);
            UpdateConflictActions();
            UpdateApplyState();
        }
    }

    private static bool PathsReferToSameProject(string candidate, string? current)
    {
        if (string.IsNullOrWhiteSpace(current)) return false;
        try
        {
            return string.Equals(
                Path.GetFullPath(candidate).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                Path.GetFullPath(current).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (
            exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return string.Equals(candidate, current, StringComparison.OrdinalIgnoreCase);
        }
    }

    private void ShowUnavailableProject(string projectRoot, Exception exception)
    {
        _session.ResetUnavailable();
        _updatingUi = true;
        try
        {
            WindowSlider.Value = ContextPolicy.Balanced400K.WindowTokens!.Value;
            WindowInputTextBox.Text = ContextDraftInput.Format(
                ContextPolicy.Balanced400K.WindowTokens.Value);
            CompactInputTextBox.Text = ContextDraftInput.Format(
                ContextPolicy.Balanced400K.CompactAtTokens!.Value);
            UpdateDraftSummary();
            UpdatePresetButtons();
        }
        finally
        {
            _updatingUi = false;
        }

        ProjectNameText.Text = "未选择可用项目";
        ProjectPathText.Text = projectRoot;
        ProjectPathText.ToolTip = projectRoot;
        TrustStatusText.Text = "路径尚未通过安全检查。";
        DiskStatusText.Text = "无法读取项目";
        StatusText.Text = exception.Message;
        WarningText.Text = "请选择一个存在、可信且不经过符号链接的本地项目目录。";
        WarningBorder.Visibility = Visibility.Visible;
        ConflictBorder.Visibility = Visibility.Collapsed;
        UpdateConflictActions();
        SetDraftEditingEnabled(false);
        OpenConfigButton.IsEnabled = false;
        ApplyButton.IsEnabled = false;
    }

    private void ApplySessionSnapshotToUi(ConfigSnapshot snapshot)
    {
        _updatingUi = true;
        try
        {
            SyncDraftControls();
            UpdateProjectText(snapshot);
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

    private void UpdateProjectText(ConfigSnapshot snapshot)
    {
        ProjectNameText.Text = new DirectoryInfo(snapshot.ProjectRoot).Name;
        ProjectPathText.Text = snapshot.ProjectRoot;
        ProjectPathText.ToolTip = snapshot.ProjectRoot;
        TrustStatusText.Text =
            "路径安全检查已通过；Codex 是否信任该项目以及配置是否实际生效，尚未验证。";
        OpenConfigButton.IsEnabled = snapshot.Exists;
    }

    private void SyncDraftControls()
    {
        var window = _session.Draft.WindowTokens ??
            (long)Math.Round(WindowSlider.Value, MidpointRounding.AwayFromZero);
        if (window < ContextPolicy.MinimumWindowTokens || window > ContextPolicy.MaximumWindowTokens)
        {
            window = ContextPolicy.Balanced400K.WindowTokens!.Value;
        }
        var compact = _session.Draft.CompactAtTokens ??
            Math.Clamp(
                (long)Math.Round(window * 0.80d, MidpointRounding.AwayFromZero),
                1,
                window - 1);
        WindowSlider.Value = window;
        WindowInputTextBox.Text = ContextDraftInput.Format(window);
        CompactInputTextBox.Text = ContextDraftInput.Format(compact);
        InputErrorText.Text = string.Empty;
        InputErrorText.Visibility = Visibility.Collapsed;
        UpdateDraftSummary();
    }

    private void UpdateDraftSummary()
    {
        if (_session.Draft.IsAuto)
        {
            WindowValueText.Text = "当前草稿：Auto；编辑数值会切换为自定义。";
            CompactValueText.Text = "Auto 不写入压缩阈值。";
            ScopeValueText.Text = _session.DraftScope == ContextPolicy.BodyAfterPrefixScope
                ? "从当前 legacy 配置创建新方案时会保留 body_after_prefix 作用域。"
                : "新建自定义方案默认使用 total 作用域。";
        }
        else
        {
            WindowValueText.Text =
                $"草稿值：{_session.Draft.WindowTokens!.Value.ToString("N0", CultureInfo.CurrentCulture)}";
            CompactValueText.Text =
                $"草稿值：{_session.Draft.CompactAtTokens!.Value.ToString("N0", CultureInfo.CurrentCulture)}";
            ScopeValueText.Text = $"压缩作用域：{_session.Draft.Scope}";
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
            var source = snapshot.Document.BlockKind == ManagedBlockKind.LegacyPlugin
                ? "旧插件块"
                : "Context Mini 块";
            DiskStatusText.Text =
                $"{source}：窗口 {snapshot.Document.WindowTokens:N0}，压缩 {snapshot.Document.CompactAtTokens:N0}，作用域 {snapshot.Document.Scope}。";
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
        if (!_session.TrySetDraft(plan)) return;
        _updatingUi = true;
        try
        {
            SyncDraftControls();
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
        if (_session.IsDirty && !_session.HasExternalConflict)
        {
            StatusText.Text = _session.IsInputValid
                ? "草稿尚未应用。"
                : "精确输入尚未通过验证；磁盘内容未改变。";
        }
        UpdateApplyState();
    }

    private void UpdatePresetButtons()
    {
        SetPresetState(AutoButton, _session.Draft.IsAuto);
        SetPresetState(CompactButton, HasPresetValues(ContextPolicy.Compact128K));
        SetPresetState(BalancedButton, HasPresetValues(ContextPolicy.Balanced400K));
        SetPresetState(OneMillionButton, HasPresetValues(ContextPolicy.OneMillion));
    }

    private bool HasPresetValues(ContextPlan preset) =>
        !_session.Draft.IsAuto &&
        _session.Draft.WindowTokens == preset.WindowTokens &&
        _session.Draft.CompactAtTokens == preset.CompactAtTokens;

    private static void SetPresetState(Button button, bool selected)
    {
        button.SetResourceReference(
            Control.BackgroundProperty,
            selected ? "SelectedControlBackgroundBrush" : "ControlBackgroundBrush");
        button.SetResourceReference(
            Control.ForegroundProperty,
            selected ? "SelectedControlTextBrush" : "PrimaryTextBrush");
    }

    private void UpdateApplyState()
    {
        ApplyButton.IsEnabled = _session.CanApply;
    }

    private void WindowSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_updatingUi || _session.IsApplyBusy || _session.IsLoadBusy || !IsLoaded) return;
        var window = Math.Clamp(
            (long)Math.Round(e.NewValue, MidpointRounding.AwayFromZero),
            ContextPolicy.MinimumWindowTokens,
            ContextPolicy.MaximumWindowTokens);
        try
        {
            SetDraft(ContextDraftInput.FromSlider(window, _session.DraftScope));
        }
        catch (ArgumentException exception)
        {
            ShowInputError(exception.Message);
        }
    }

    private void ExactValue_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_updatingUi || _session.IsApplyBusy || _session.IsLoadBusy || !IsLoaded) return;
        if (!ContextDraftInput.TryCreate(
                WindowInputTextBox.Text,
                CompactInputTextBox.Text,
                _session.DraftScope,
                out var plan,
                out var error))
        {
            _session.MarkInputInvalid();
            ShowInputError(error);
            RecalculateDirty();
            return;
        }

        _updatingUi = true;
        try
        {
            if (!_session.TrySetDraft(plan)) return;
            WindowSlider.Value = plan.WindowTokens!.Value;
            InputErrorText.Text = string.Empty;
            InputErrorText.Visibility = Visibility.Collapsed;
            UpdateDraftSummary();
            UpdatePresetButtons();
            RecalculateDirty();
        }
        finally
        {
            _updatingUi = false;
        }
    }

    private void ShowInputError(string error)
    {
        InputErrorText.Text = error;
        InputErrorText.Visibility = Visibility.Visible;
        UpdateApplyState();
    }

    private void Appearance_Click(object sender, RoutedEventArgs e)
    {
        if (_updatingAppearance ||
            sender is not RadioButton { Tag: AppearancePreference preference })
        {
            return;
        }

        try
        {
            var result = _appearance.SetPreference(preference);
            UpdatePresetButtons();
            if (!result.Saved)
            {
                MessageBox.Show(
                    this,
                    $"主题已切换，但无法保存外观选择：{result.ErrorMessage}",
                    "无法保存外观选择",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }
        catch (Exception exception)
        {
            UpdateAppearanceSelector();
            MessageBox.Show(
                this,
                exception.Message,
                "无法切换主题",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }

    private void Auto_Click(object sender, RoutedEventArgs e) => SetDraft(ContextPolicy.Auto);
    private void Compact_Click(object sender, RoutedEventArgs e) => SetPreset(ContextPolicy.Compact128K);
    private void Balanced_Click(object sender, RoutedEventArgs e) => SetPreset(ContextPolicy.Balanced400K);
    private void OneMillion_Click(object sender, RoutedEventArgs e) => SetPreset(ContextPolicy.OneMillion);

    private void SetPreset(ContextPlan preset) =>
        SetDraft(ContextDraftInput.FromPreset(preset, _session.DraftScope));

    private async void Reload_Click(object sender, RoutedEventArgs e)
    {
        if (_session.IsApplyBusy || _session.IsLoadBusy || _session.ProjectRoot is null) return;

        if (_session.IsDirty || !_session.IsInputValid)
        {
            var choice = MessageBox.Show(
                this,
                "当前草稿尚未应用。\n\n“是”：保留草稿，并把最新磁盘配置设为新的写入基线。\n“否”：明确丢弃草稿，并使用最新磁盘配置。\n“取消”：保持现状。",
                "重新加载配置",
                MessageBoxButton.YesNoCancel,
                MessageBoxImage.Warning);
            if (choice == MessageBoxResult.Cancel) return;
            if (_session.PendingExternalSnapshot is not null)
            {
                if (choice == MessageBoxResult.Yes) RebaseOnPendingSnapshot();
                else DiscardDraftAndUsePendingSnapshot(requireConfirmation: false);
                return;
            }

            await LoadProjectAsync(
                _session.ProjectRoot,
                preserveDraft: choice == MessageBoxResult.Yes,
                resetOnFailure: false);
            return;
        }

        await LoadProjectAsync(_session.ProjectRoot, preserveDraft: false, resetOnFailure: false);
    }

    private async void SwitchProject_Click(object sender, RoutedEventArgs e)
    {
        if (_session.IsApplyBusy || _session.IsLoadBusy) return;
        if (!ConfirmProjectSwitch()) return;
        await PromptForProjectAsync();
    }

    private async Task PromptForProjectAsync()
    {
        var initialDirectory = _session.ProjectRoot;
        if (string.IsNullOrWhiteSpace(initialDirectory) || !Directory.Exists(initialDirectory))
        {
            initialDirectory = Directory.Exists(_initialProject)
                ? _initialProject
                : Environment.CurrentDirectory;
        }

        var dialog = new OpenFolderDialog
        {
            Title = "选择 Codex 项目目录",
            Multiselect = false,
            InitialDirectory = initialDirectory,
        };
        if (dialog.ShowDialog(this) == true)
        {
            await LoadProjectAsync(
                dialog.FolderName,
                preserveDraft: false,
                resetOnFailure: _session.Snapshot is null);
        }
    }

    private bool ConfirmProjectSwitch() =>
        (!_session.IsDirty && _session.IsInputValid) ||
        MessageBox.Show(
            this,
            "切换项目会放弃尚未应用的草稿。继续吗？",
            "Context Mini",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning) == MessageBoxResult.Yes;

    private async void OpenRecentProject_Click(object sender, RoutedEventArgs e)
    {
        if (_session.IsApplyBusy || _session.IsLoadBusy) return;
        if (RecentProjectsCombo.SelectedItem is not string projectRoot) return;
        if (string.Equals(projectRoot, _session.ProjectRoot, StringComparison.OrdinalIgnoreCase)) return;
        if (!ConfirmProjectSwitch()) return;
        await LoadProjectAsync(projectRoot, preserveDraft: false, resetOnFailure: _session.Snapshot is null);
    }

    private async void Apply_Click(object sender, RoutedEventArgs e)
    {
        var ticket = _session.TryCreateApplyTicket();
        if (ticket is null) return;
        // MessageBox runs a nested dispatcher loop. Pause future monitor ticks before
        // showing the preview so an ordinary unchanged poll does not stale it; a poll
        // already in flight can still invalidate the ticket conservatively.
        _monitor.Stop();

        string preview;
        try
        {
            preview = ConfigurationPresentation.BuildManagedBlockPreview(ticket.Expected, ticket.Plan);
        }
        catch (Exception exception)
        {
            if (!_session.IsClosed) _monitor.Start();
            MessageBox.Show(this, exception.Message, "无法生成变更预览", MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }

        var profileText = ticket.Plan.IsAuto
            ? "Auto（移除 Context Mini/旧插件管理块）"
            : $"窗口 {ticket.Plan.WindowTokens:N0}，压缩 {ticket.Plan.CompactAtTokens:N0}，作用域 {ticket.Plan.Scope}";
        var confirmation =
            $"目标项目：{ticket.Expected.ProjectRoot}\n配置文件：{ticket.Expected.ConfigPath}\n计划：{profileText}\n\n{preview}\n\n确认写入？";
        if (MessageBox.Show(
                this,
                confirmation,
                "预览并确认应用",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question) != MessageBoxResult.Yes)
        {
            if (!_session.IsClosed) _monitor.Start();
            return;
        }

        SetDraftEditingEnabled(false);
        ApplyButton.IsEnabled = false;
        StatusText.Text = "正在安全写入配置…";
        try
        {
            var outcome = await _session.ApplyAsync(ticket);
            if (_session.IsClosed) return;
            if (outcome.Kind == SessionApplyKind.StalePreview)
            {
                StatusText.Text = "配置或草稿在确认期间发生变化；未写入磁盘，请重新预览。";
                MessageBox.Show(
                    this,
                    "配置或草稿在确认期间发生变化。为避免应用与预览不一致，本次未写入；请重新预览后再试。",
                    "需要重新预览",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }
            if (!outcome.Succeeded || outcome.Result is null)
            {
                var exception = outcome.Error ?? new IOException("The configuration could not be applied.");
                StatusText.Text = exception.Message;
                if (_session.HasExternalConflict)
                {
                    if (_session.PendingExternalSnapshot is not null)
                    {
                        ShowPendingConflictVisual(
                            "写入前配置身份或内容已变化。你的草稿仍保留，请选择重新基于新配置或明确丢弃草稿。",
                            "写入前检测到磁盘变化；草稿未被覆盖，请先处理冲突。");
                    }
                    else
                    {
                        ShowReloadRequired(
                            $"写入前无法重新确认磁盘基线：{exception.Message}",
                            "草稿已保留且应用已锁定；请重新读取磁盘后再处理。");
                    }
                }
                MessageBox.Show(this, exception.Message, "无法应用", MessageBoxButton.OK, MessageBoxImage.Error);
                return;
            }

            var result = outcome.Result;
            ClearExternalConflictVisual();
            ApplySessionSnapshotToUi(result.Snapshot);
            RememberProject(result.Snapshot.ProjectRoot);
            StatusText.Text = result.Changed
                ? "应用成功。请新建 Codex 任务或重启应用后验证是否实际生效。"
                : "磁盘内容已经与草稿一致。";
        }
        finally
        {
            SetDraftEditingEnabled(_session.Snapshot is not null);
            UpdateConflictActions();
            UpdateApplyState();
            if (!_session.IsClosed) _monitor.Start();
        }
    }

    private async void Monitor_Tick(object? sender, EventArgs e)
    {
        var outcome = await _session.MonitorAsync();
        if (_session.IsClosed) return;

        switch (outcome.Kind)
        {
            case SessionMonitorKind.Skipped:
            case SessionMonitorKind.Superseded:
            case SessionMonitorKind.PendingUnchanged:
                return;

            case SessionMonitorKind.Unchanged:
            case SessionMonitorKind.Recovered:
            {
                var snapshot = outcome.Snapshot!;
                ClearExternalConflictVisual();
                UpdateProjectText(snapshot);
                UpdateDiskStatus(snapshot);
                UpdateWarning(snapshot);
                RecalculateDirty();
                if (outcome.Kind == SessionMonitorKind.Recovered)
                {
                    StatusText.Text = "磁盘内容已回到当前基线；过期的外部快照已清除，草稿保持不变。";
                }
                return;
            }

            case SessionMonitorKind.Conflict:
                ShowPendingConflictVisual(
                    "配置已被外部修改。你的草稿仍完整保留；应用已锁定，直到你选择重新基于新配置或明确丢弃草稿。",
                    "检测到外部修改。草稿未被覆盖，请使用上方冲突处理选项。");
                return;

            case SessionMonitorKind.Refreshed:
            {
                var snapshot = outcome.Snapshot!;
                ClearExternalConflictVisual();
                ApplySessionSnapshotToUi(snapshot);
                StatusText.Text = "检测到外部修改，界面已自动刷新。";
                return;
            }

            case SessionMonitorKind.Failed:
                ShowReloadRequired(
                    $"后台监控无法读取配置：{outcome.Error!.Message}",
                    "后台监控读取失败，应用已锁定；草稿未改变，请重新读取磁盘。");
                return;
        }
    }

    private void RebaseDraft_Click(object sender, RoutedEventArgs e) => RebaseOnPendingSnapshot();

    private void RebaseOnPendingSnapshot()
    {
        if (!_session.TryRebasePending() || _session.Snapshot is not { } snapshot) return;

        ClearExternalConflictVisual();
        UpdateProjectText(snapshot);
        UpdateDiskStatus(snapshot);
        UpdateWarning(snapshot);
        UpdateDraftSummary();
        UpdateApplyState();
        StatusText.Text = _session.IsInputValid
            ? "已将最新磁盘配置设为新基线；当前草稿保持不变，请预览后应用。"
            : "已将最新磁盘配置设为新基线；未完成的精确输入保持不变，请先修正。";
    }

    private void ViewExternalChanges_Click(object sender, RoutedEventArgs e)
    {
        if (_session.Snapshot is not { } snapshot ||
            _session.PendingExternalSnapshot is not { } pending ||
            _session.IsLoadBusy ||
            _session.IsApplyBusy)
        {
            return;
        }
        var preview = ConfigurationPresentation.BuildExternalChangePreview(
            snapshot,
            pending);
        new TextPreviewWindow(
            this,
            "外部配置变化",
            "以下内容仅供比较，不会写入磁盘。你的草稿仍保持不变。",
            preview).ShowDialog();
    }

    private void DiscardDraft_Click(object sender, RoutedEventArgs e) =>
        DiscardDraftAndUsePendingSnapshot(requireConfirmation: true);

    private void DiscardDraftAndUsePendingSnapshot(bool requireConfirmation)
    {
        if (_session.PendingExternalSnapshot is null || _session.IsLoadBusy || _session.IsApplyBusy) return;
        if (requireConfirmation &&
            MessageBox.Show(
                this,
                "这会永久放弃当前未应用的草稿，并采用磁盘最新配置。继续吗？",
                "丢弃草稿",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning) != MessageBoxResult.Yes)
        {
            return;
        }

        if (!_session.TryDiscardPending() || _session.Snapshot is not { } latest) return;
        ClearExternalConflictVisual();
        ApplySessionSnapshotToUi(latest);
        StatusText.Text = "已明确丢弃原草稿，并加载磁盘最新配置。";
    }

    private void ClearExternalConflictVisual()
    {
        ConflictBorder.Visibility = Visibility.Collapsed;
        UpdateConflictActions();
    }

    private void ShowPendingConflictVisual(string message, string status)
    {
        ConflictTitleText.Text = "检测到外部修改";
        ConflictText.Text = message;
        ConflictBorder.Visibility = Visibility.Visible;
        StatusText.Text = status;
        UpdateConflictActions();
        UpdateApplyState();
    }

    private void ShowReloadRequired(string message, string status)
    {
        ConflictTitleText.Text = "需要重新读取配置";
        ConflictText.Text = message;
        ConflictBorder.Visibility = Visibility.Visible;
        StatusText.Text = status;
        UpdateConflictActions();
        UpdateApplyState();
    }

    private void UpdateConflictActions()
    {
        var pendingAvailable = _session.PendingExternalSnapshot is not null;
        var actionsEnabled = !_session.IsLoadBusy && !_session.IsApplyBusy && !_session.IsClosed;
        RebaseDraftButton.IsEnabled = pendingAvailable && actionsEnabled;
        ViewExternalChangesButton.IsEnabled = pendingAvailable && actionsEnabled;
        DiscardDraftButton.IsEnabled = pendingAvailable && actionsEnabled;
        ReloadConflictButton.IsEnabled = _session.ProjectRoot is not null && actionsEnabled;
    }

    private void SetDraftEditingEnabled(bool enabled)
    {
        AutoButton.IsEnabled = enabled;
        CompactButton.IsEnabled = enabled;
        BalancedButton.IsEnabled = enabled;
        OneMillionButton.IsEnabled = enabled;
        WindowSlider.IsEnabled = enabled;
        WindowInputTextBox.IsEnabled = enabled;
        CompactInputTextBox.IsEnabled = enabled;
    }

    private void OpenConfig_Click(object sender, RoutedEventArgs e)
    {
        if (_session.Snapshot is not { Exists: true } snapshot) return;
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = snapshot.ConfigPath,
                UseShellExecute = true,
            });
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                this,
                $"无法打开 config.toml：{exception.Message}",
                "打开失败",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }

    private void CopyDiagnostics_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Clipboard.SetText(ConfigurationPresentation.BuildDiagnostics(
                _session.Snapshot,
                _session.Draft,
                _session.IsDirty,
                _session.HasExternalConflict,
                StatusText.Text));
            StatusText.Text = "诊断信息已复制到剪贴板；其中包含项目和配置文件路径。";
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                this,
                $"无法复制诊断信息：{exception.Message}",
                "复制失败",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }

    private void RememberProject(string projectRoot)
    {
        try
        {
            _recentProjects.Remember(projectRoot);
            RefreshRecentProjects();
        }
        catch (Exception exception)
        {
            Debug.WriteLine($"Could not save recent project: {exception}");
        }
    }

    private void RefreshRecentProjects()
    {
        try
        {
            var projects = _recentProjects.Load();
            RecentProjectsCombo.ItemsSource = projects;
            RecentProjectsCombo.SelectedItem = projects.FirstOrDefault(path =>
                string.Equals(path, _session.ProjectRoot, StringComparison.OrdinalIgnoreCase));
            if (RecentProjectsCombo.SelectedItem is null && projects.Count > 0)
            {
                RecentProjectsCombo.SelectedIndex = 0;
            }
        }
        catch (Exception exception)
        {
            RecentProjectsCombo.ItemsSource = Array.Empty<string>();
            Debug.WriteLine($"Could not load recent projects: {exception}");
        }
    }
}
