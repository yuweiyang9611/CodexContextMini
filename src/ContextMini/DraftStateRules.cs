using ContextMini.Core;

namespace ContextMini;

internal static class DraftStateRules
{
    public static bool MatchesDisk(ContextPlan plan, ConfigSnapshot snapshot)
    {
        if (snapshot.Document.BlockKind == ManagedBlockKind.LegacyPlugin) return false;
        if (plan.IsAuto) return !snapshot.ManagedBlockPresent;
        return snapshot.ManagedBlockPresent &&
               snapshot.Document.WindowTokens == plan.WindowTokens &&
               snapshot.Document.CompactAtTokens == plan.CompactAtTokens &&
               string.Equals(snapshot.Document.Scope, plan.Scope, StringComparison.Ordinal);
    }

    public static DraftRebaseResult Rebase(ContextPlan draft, ConfigSnapshot latest) =>
        new(draft, latest, !MatchesDisk(draft, latest));

    public static ExternalSnapshotRelation RelateExternalSnapshot(
        ConfigSnapshot baseline,
        ConfigSnapshot? pending,
        ConfigSnapshot latest)
    {
        if (string.Equals(latest.Fingerprint, baseline.Fingerprint, StringComparison.Ordinal))
        {
            return ExternalSnapshotRelation.BaselineEquivalent;
        }
        if (pending is not null &&
            string.Equals(latest.Fingerprint, pending.Fingerprint, StringComparison.Ordinal))
        {
            return ExternalSnapshotRelation.PendingEquivalent;
        }
        return ExternalSnapshotRelation.Changed;
    }
}

internal sealed record DraftRebaseResult(ContextPlan Draft, ConfigSnapshot Snapshot, bool IsDirty);

internal enum ExternalSnapshotRelation
{
    BaselineEquivalent,
    PendingEquivalent,
    Changed,
}
