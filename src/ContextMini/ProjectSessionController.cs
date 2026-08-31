using ContextMini.Core;

namespace ContextMini;

internal interface IProjectSessionStore
{
    Task<ConfigSnapshot> LoadAsync(string projectRoot);
    Task<ApplyResult> ApplyAsync(ConfigSnapshot expected, ContextPlan plan);
}

internal sealed class ProjectSessionFileStore : IProjectSessionStore
{
    private readonly ProjectConfigStore _store;

    public ProjectSessionFileStore(ProjectConfigStore? store = null)
    {
        _store = store ?? new ProjectConfigStore();
    }

    public Task<ConfigSnapshot> LoadAsync(string projectRoot) =>
        Task.Run(() => _store.Load(projectRoot));

    public Task<ApplyResult> ApplyAsync(ConfigSnapshot expected, ContextPlan plan) =>
        Task.Run(() => _store.Apply(expected, plan));
}

internal sealed class ProjectSessionController
{
    private readonly IProjectSessionStore _store;
    private long _loadGeneration;
    private long _operationVersion;

    public ProjectSessionController(IProjectSessionStore store)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
    }

    public ConfigSnapshot? Snapshot { get; private set; }
    public ConfigSnapshot? PendingExternalSnapshot { get; private set; }
    public ContextPlan Draft { get; private set; } = ContextPolicy.Auto;
    public string DraftScope { get; private set; } = ContextPolicy.TotalScope;
    public string? ProjectRoot { get; private set; }
    public bool IsDirty { get; private set; }
    public bool HasExternalConflict { get; private set; }
    public bool IsInputValid { get; private set; } = true;
    public bool IsApplyBusy { get; private set; }
    public bool IsLoadBusy { get; private set; }
    public bool IsMonitorBusy { get; private set; }
    public bool IsClosed { get; private set; }

    public bool CanApply => Snapshot is not null &&
                            Snapshot.Document.CanWrite &&
                            IsDirty &&
                            IsInputValid &&
                            !IsApplyBusy &&
                            !IsLoadBusy &&
                            !HasExternalConflict &&
                            !IsClosed;

    public bool CanClose => !IsApplyBusy;

    public async Task<SessionLoadOutcome> LoadProjectAsync(string projectRoot, bool preserveDraft)
    {
        if (IsClosed || IsApplyBusy)
        {
            return SessionLoadOutcome.SkippedOutcome(ProjectRoot);
        }

        var generation = ++_loadGeneration;
        _operationVersion++;
        var previousProjectRoot = ProjectRoot;
        var preservedDraft = Draft;
        var preservedScope = DraftScope;
        var preservedInputValid = IsInputValid;
        IsLoadBusy = true;
        try
        {
            var snapshot = await _store.LoadAsync(projectRoot);
            if (IsClosed || generation != _loadGeneration)
            {
                return SessionLoadOutcome.SupersededOutcome(previousProjectRoot);
            }

            Snapshot = snapshot;
            ProjectRoot = snapshot.ProjectRoot;
            ClearConflict();
            if (preserveDraft)
            {
                Draft = preservedDraft;
                DraftScope = preservedScope;
                IsInputValid = preservedInputValid;
                RecalculateDirty();
            }
            else
            {
                AdoptSnapshot(snapshot);
            }
            return SessionLoadOutcome.Success(snapshot, previousProjectRoot);
        }
        catch (Exception exception)
        {
            return IsClosed || generation != _loadGeneration
                ? SessionLoadOutcome.SupersededOutcome(previousProjectRoot)
                : SessionLoadOutcome.Failure(exception, previousProjectRoot);
        }
        finally
        {
            if (generation == _loadGeneration) IsLoadBusy = false;
        }
    }

    public bool TrySetDraft(ContextPlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        if (Snapshot is null || IsClosed || IsApplyBusy || IsLoadBusy) return false;
        ContextPolicy.Validate(plan);
        Draft = plan;
        if (!plan.IsAuto) DraftScope = ContextDraftInput.NormalizeScope(plan.Scope);
        IsInputValid = true;
        RecalculateDirty();
        _operationVersion++;
        return true;
    }

    public bool MarkInputInvalid()
    {
        if (Snapshot is null || IsClosed || IsApplyBusy || IsLoadBusy) return false;
        IsInputValid = false;
        RecalculateDirty();
        _operationVersion++;
        return true;
    }

    public SessionApplyTicket? TryCreateApplyTicket() => CanApply && Snapshot is not null
        ? new SessionApplyTicket(Snapshot, Draft, _operationVersion)
        : null;

    public Task<SessionApplyOutcome> ApplyAsync()
    {
        var ticket = TryCreateApplyTicket();
        return ticket is null
            ? Task.FromResult(SessionApplyOutcome.SkippedOutcome())
            : ApplyAsync(ticket);
    }

    public async Task<SessionApplyOutcome> ApplyAsync(SessionApplyTicket ticket)
    {
        ArgumentNullException.ThrowIfNull(ticket);
        if (!CanApply || Snapshot is null ||
            ticket.OperationVersion != _operationVersion ||
            !string.Equals(ticket.Expected.ConfigPath, Snapshot.ConfigPath, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(ticket.Expected.Fingerprint, Snapshot.Fingerprint, StringComparison.Ordinal) ||
            ticket.Plan != Draft)
        {
            return SessionApplyOutcome.StalePreviewOutcome();
        }

        var expected = ticket.Expected;
        var plan = ticket.Plan;
        _operationVersion++;
        IsApplyBusy = true;
        try
        {
            var result = await _store.ApplyAsync(expected, plan);
            if (IsClosed) return SessionApplyOutcome.SupersededOutcome();

            Snapshot = result.Snapshot;
            ProjectRoot = result.Snapshot.ProjectRoot;
            ClearConflict();
            AdoptSnapshot(result.Snapshot);
            return SessionApplyOutcome.Success(result);
        }
        catch (Exception exception)
        {
            if (IsClosed) return SessionApplyOutcome.SupersededOutcome(exception);
            if (exception is ConfigConflictException)
            {
                RequireReload();
                await TryPopulatePendingSnapshotAsync();
                if (IsClosed) return SessionApplyOutcome.SupersededOutcome(exception);
            }
            return SessionApplyOutcome.Failure(exception, PendingExternalSnapshot is not null);
        }
        finally
        {
            IsApplyBusy = false;
        }
    }

    public async Task<SessionMonitorOutcome> MonitorAsync()
    {
        if (IsClosed || IsMonitorBusy || IsLoadBusy || IsApplyBusy || Snapshot is null || ProjectRoot is null)
        {
            return SessionMonitorOutcome.SkippedOutcome();
        }

        IsMonitorBusy = true;
        var baseline = Snapshot;
        var projectRoot = ProjectRoot;
        var operationVersion = _operationVersion;
        try
        {
            var latest = await _store.LoadAsync(projectRoot);
            if (!IsStillCurrent(baseline, projectRoot, operationVersion))
            {
                return SessionMonitorOutcome.SupersededOutcome();
            }

            var relation = DraftStateRules.RelateExternalSnapshot(
                baseline,
                PendingExternalSnapshot,
                latest);
            if (relation == ExternalSnapshotRelation.BaselineEquivalent)
            {
                var recovered = HasExternalConflict;
                Snapshot = latest;
                ClearConflict();
                RecalculateDirty();
                // A byte-identical replacement can still have a different filesystem
                // identity, so previews from the previous snapshot are now stale.
                _operationVersion++;
                return recovered
                    ? SessionMonitorOutcome.Recovered(latest)
                    : SessionMonitorOutcome.Unchanged(latest);
            }
            if (relation == ExternalSnapshotRelation.PendingEquivalent)
            {
                return SessionMonitorOutcome.PendingUnchanged(latest);
            }

            if (IsDirty || !IsInputValid)
            {
                PendingExternalSnapshot = latest;
                HasExternalConflict = true;
                _operationVersion++;
                return SessionMonitorOutcome.Conflict(latest);
            }

            Snapshot = latest;
            ProjectRoot = latest.ProjectRoot;
            ClearConflict();
            AdoptSnapshot(latest);
            _operationVersion++;
            return SessionMonitorOutcome.Refreshed(latest);
        }
        catch (Exception exception)
        {
            if (!IsStillCurrent(baseline, projectRoot, operationVersion))
            {
                return SessionMonitorOutcome.SupersededOutcome();
            }
            RequireReload();
            return SessionMonitorOutcome.Failure(exception);
        }
        finally
        {
            IsMonitorBusy = false;
        }
    }

    public bool TryRebasePending()
    {
        if (PendingExternalSnapshot is null || IsClosed || IsLoadBusy || IsApplyBusy) return false;
        var latest = PendingExternalSnapshot;
        Snapshot = latest;
        ProjectRoot = latest.ProjectRoot;
        if (Draft.IsAuto) DraftScope = ContextDraftInput.NormalizeScope(latest.Document.Scope);
        IsDirty = !IsInputValid || !DraftStateRules.MatchesDisk(Draft, latest);
        ClearConflict();
        _operationVersion++;
        return true;
    }

    public bool TryDiscardPending()
    {
        if (PendingExternalSnapshot is null || IsClosed || IsLoadBusy || IsApplyBusy) return false;
        var latest = PendingExternalSnapshot;
        Snapshot = latest;
        ProjectRoot = latest.ProjectRoot;
        ClearConflict();
        AdoptSnapshot(latest);
        _operationVersion++;
        return true;
    }

    public void RequireReload()
    {
        PendingExternalSnapshot = null;
        HasExternalConflict = true;
        _operationVersion++;
    }

    public void ResetUnavailable()
    {
        _loadGeneration++;
        _operationVersion++;
        Snapshot = null;
        PendingExternalSnapshot = null;
        ProjectRoot = null;
        Draft = ContextPolicy.Auto;
        DraftScope = ContextPolicy.TotalScope;
        IsDirty = false;
        HasExternalConflict = false;
        IsInputValid = true;
        IsLoadBusy = false;
    }

    public void Close()
    {
        IsClosed = true;
        _loadGeneration++;
        _operationVersion++;
        IsLoadBusy = false;
    }

    private async Task<bool> TryPopulatePendingSnapshotAsync()
    {
        if (ProjectRoot is null || Snapshot is null) return false;
        var projectRoot = ProjectRoot;
        var baseline = Snapshot;
        try
        {
            var latest = await _store.LoadAsync(projectRoot);
            if (IsClosed || !ReferenceEquals(Snapshot, baseline) ||
                !string.Equals(ProjectRoot, projectRoot, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }
            PendingExternalSnapshot = latest;
            HasExternalConflict = true;
            return true;
        }
        catch
        {
            return false;
        }
    }

    private bool IsStillCurrent(ConfigSnapshot baseline, string projectRoot, long operationVersion) =>
        !IsClosed &&
        operationVersion == _operationVersion &&
        !IsLoadBusy &&
        !IsApplyBusy &&
        ReferenceEquals(Snapshot, baseline) &&
        string.Equals(ProjectRoot, projectRoot, StringComparison.OrdinalIgnoreCase);

    private void AdoptSnapshot(ConfigSnapshot snapshot)
    {
        DraftScope = ContextDraftInput.NormalizeScope(snapshot.Document.Scope);
        Draft = ResolveSnapshotPlan(snapshot);
        IsInputValid = true;
        RecalculateDirty();
    }

    private void RecalculateDirty()
    {
        IsDirty = Snapshot is not null &&
            (!IsInputValid || !DraftStateRules.MatchesDisk(Draft, Snapshot));
    }

    private void ClearConflict()
    {
        PendingExternalSnapshot = null;
        HasExternalConflict = false;
    }

    private static ContextPlan ResolveSnapshotPlan(ConfigSnapshot snapshot)
    {
        if (!snapshot.ManagedBlockPresent) return ContextPolicy.Auto;
        var scope = snapshot.Document.Scope ?? ContextPolicy.TotalScope;
        try
        {
            return ContextPolicy.Resolve(
                snapshot.Document.WindowTokens!.Value,
                snapshot.Document.CompactAtTokens!.Value,
                scope);
        }
        catch (ArgumentException) when (snapshot.Document.BlockKind == ManagedBlockKind.LegacyPlugin)
        {
            return ContextPolicy.Auto;
        }
    }
}

internal enum SessionLoadKind
{
    Succeeded,
    Failed,
    Superseded,
    Skipped,
}

internal sealed record SessionLoadOutcome(
    SessionLoadKind Kind,
    ConfigSnapshot? Snapshot,
    Exception? Error,
    string? PreviousProjectRoot)
{
    public bool Succeeded => Kind == SessionLoadKind.Succeeded;
    public bool Superseded => Kind == SessionLoadKind.Superseded;
    public static SessionLoadOutcome Success(ConfigSnapshot snapshot, string? previous) =>
        new(SessionLoadKind.Succeeded, snapshot, null, previous);
    public static SessionLoadOutcome Failure(Exception error, string? previous) =>
        new(SessionLoadKind.Failed, null, error, previous);
    public static SessionLoadOutcome SupersededOutcome(string? previous) =>
        new(SessionLoadKind.Superseded, null, null, previous);
    public static SessionLoadOutcome SkippedOutcome(string? previous) =>
        new(SessionLoadKind.Skipped, null, null, previous);
}

internal enum SessionApplyKind
{
    Succeeded,
    Failed,
    Superseded,
    Skipped,
    StalePreview,
}

internal sealed record SessionApplyTicket(
    ConfigSnapshot Expected,
    ContextPlan Plan,
    long OperationVersion);

internal sealed record SessionApplyOutcome(
    SessionApplyKind Kind,
    ApplyResult? Result,
    Exception? Error,
    bool PendingSnapshotAvailable)
{
    public bool Succeeded => Kind == SessionApplyKind.Succeeded;
    public bool Superseded => Kind == SessionApplyKind.Superseded;
    public static SessionApplyOutcome Success(ApplyResult result) =>
        new(SessionApplyKind.Succeeded, result, null, false);
    public static SessionApplyOutcome Failure(Exception error, bool pending) =>
        new(SessionApplyKind.Failed, null, error, pending);
    public static SessionApplyOutcome SupersededOutcome(Exception? error = null) =>
        new(SessionApplyKind.Superseded, null, error, false);
    public static SessionApplyOutcome SkippedOutcome() =>
        new(SessionApplyKind.Skipped, null, null, false);
    public static SessionApplyOutcome StalePreviewOutcome() =>
        new(SessionApplyKind.StalePreview, null, null, false);
}

internal enum SessionMonitorKind
{
    Skipped,
    Superseded,
    Unchanged,
    Recovered,
    PendingUnchanged,
    Conflict,
    Refreshed,
    Failed,
}

internal sealed record SessionMonitorOutcome(
    SessionMonitorKind Kind,
    ConfigSnapshot? Snapshot,
    Exception? Error)
{
    public static SessionMonitorOutcome SkippedOutcome() => new(SessionMonitorKind.Skipped, null, null);
    public static SessionMonitorOutcome SupersededOutcome() => new(SessionMonitorKind.Superseded, null, null);
    public static SessionMonitorOutcome Unchanged(ConfigSnapshot snapshot) => new(SessionMonitorKind.Unchanged, snapshot, null);
    public static SessionMonitorOutcome Recovered(ConfigSnapshot snapshot) => new(SessionMonitorKind.Recovered, snapshot, null);
    public static SessionMonitorOutcome PendingUnchanged(ConfigSnapshot snapshot) => new(SessionMonitorKind.PendingUnchanged, snapshot, null);
    public static SessionMonitorOutcome Conflict(ConfigSnapshot snapshot) => new(SessionMonitorKind.Conflict, snapshot, null);
    public static SessionMonitorOutcome Refreshed(ConfigSnapshot snapshot) => new(SessionMonitorKind.Refreshed, snapshot, null);
    public static SessionMonitorOutcome Failure(Exception error) => new(SessionMonitorKind.Failed, null, error);
}
