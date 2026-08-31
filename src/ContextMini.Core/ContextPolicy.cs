namespace ContextMini.Core;

public static class ContextPolicy
{
    public const long MinimumWindowTokens = 8_192;
    public const long MaximumWindowTokens = 1_050_000;
    public const string TotalScope = "total";
    public const string BodyAfterPrefixScope = "body_after_prefix";

    public static ContextPlan Auto { get; } = new(ContextProfile.Auto, null, null);
    public static ContextPlan Compact128K { get; } = new(ContextProfile.Compact128K, 128_000, 96_000);
    public static ContextPlan Balanced400K { get; } = new(ContextProfile.Balanced400K, 400_000, 320_000);
    public static ContextPlan OneMillion { get; } = new(ContextProfile.OneMillion, 1_050_000, 850_000);

    public static ContextPlan Custom(long windowTokens)
    {
        ValidateWindow(windowTokens);
        var compactAt = Math.Clamp(
            (long)Math.Round(windowTokens * 0.80d, MidpointRounding.AwayFromZero),
            1,
            windowTokens - 1);
        return new ContextPlan(ContextProfile.Custom, windowTokens, compactAt);
    }

    public static ContextPlan Resolve(long windowTokens, long compactAtTokens, string scope)
    {
        Validate(windowTokens, compactAtTokens, scope);
        if (scope == TotalScope && windowTokens == Compact128K.WindowTokens && compactAtTokens == Compact128K.CompactAtTokens)
        {
            return Compact128K;
        }
        if (scope == TotalScope && windowTokens == Balanced400K.WindowTokens && compactAtTokens == Balanced400K.CompactAtTokens)
        {
            return Balanced400K;
        }
        if (scope == TotalScope && windowTokens == OneMillion.WindowTokens && compactAtTokens == OneMillion.CompactAtTokens)
        {
            return OneMillion;
        }
        return new ContextPlan(ContextProfile.Custom, windowTokens, compactAtTokens, scope);
    }

    public static void Validate(ContextPlan plan)
    {
        if (plan.IsAuto)
        {
            if (plan.WindowTokens is not null || plan.CompactAtTokens is not null)
            {
                throw new ArgumentException("Auto must not define token values.", nameof(plan));
            }
            return;
        }

        if (plan.WindowTokens is null || plan.CompactAtTokens is null)
        {
            throw new ArgumentException("A non-Auto profile requires window and compaction values.", nameof(plan));
        }
        Validate(plan.WindowTokens.Value, plan.CompactAtTokens.Value, plan.Scope);
    }

    public static void Validate(long windowTokens, long compactAtTokens, string scope)
    {
        ValidateWindow(windowTokens);
        if (compactAtTokens <= 0 || compactAtTokens >= windowTokens)
        {
            throw new ArgumentOutOfRangeException(nameof(compactAtTokens), "Compaction must be positive and below the window.");
        }
        if (!string.Equals(scope, TotalScope, StringComparison.Ordinal) &&
            !string.Equals(scope, BodyAfterPrefixScope, StringComparison.Ordinal))
        {
            throw new ArgumentException("Compaction scope must be total or body_after_prefix.", nameof(scope));
        }
    }

    private static void ValidateWindow(long windowTokens)
    {
        if (windowTokens < MinimumWindowTokens || windowTokens > MaximumWindowTokens)
        {
            throw new ArgumentOutOfRangeException(nameof(windowTokens), $"Window must be between {MinimumWindowTokens:N0} and {MaximumWindowTokens:N0}.");
        }
    }
}
