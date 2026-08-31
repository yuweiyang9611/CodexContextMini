using System.Globalization;
using ContextMini.Core;

namespace ContextMini;

internal static class ContextDraftInput
{
    public static bool TryCreate(
        string windowText,
        string compactText,
        string? scope,
        out ContextPlan plan,
        out string error)
    {
        plan = ContextPolicy.Auto;
        if (!TryParseTokenCount(windowText, out var window))
        {
            error = "上下文请求值必须是整数。";
            return false;
        }
        if (!TryParseTokenCount(compactText, out var compact))
        {
            error = "自动压缩阈值必须是整数。";
            return false;
        }

        var effectiveScope = string.IsNullOrWhiteSpace(scope) ? ContextPolicy.TotalScope : scope;
        try
        {
            plan = string.Equals(effectiveScope, ContextPolicy.TotalScope, StringComparison.Ordinal)
                ? ContextPolicy.Resolve(window, compact, effectiveScope)
                : new ContextPlan(ContextProfile.Custom, window, compact, effectiveScope);
            ContextPolicy.Validate(plan);
            error = string.Empty;
            return true;
        }
        catch (ArgumentException exception)
        {
            error = $"数值无效：{exception.Message}";
            return false;
        }
    }

    public static ContextPlan FromSlider(long window, string? scope)
    {
        var compact = Math.Clamp(
            (long)Math.Round(window * 0.80d, MidpointRounding.AwayFromZero),
            1,
            window - 1);
        var plan = new ContextPlan(
            ContextProfile.Custom,
            window,
            compact,
            string.IsNullOrWhiteSpace(scope) ? ContextPolicy.TotalScope : scope);
        ContextPolicy.Validate(plan);
        return plan;
    }

    public static ContextPlan FromPreset(ContextPlan preset, string? currentScope)
    {
        ArgumentNullException.ThrowIfNull(preset);
        if (preset.IsAuto) return ContextPolicy.Auto;
        var scope = string.IsNullOrWhiteSpace(currentScope)
            ? ContextPolicy.TotalScope
            : currentScope;
        var plan = ContextPolicy.Resolve(
            preset.WindowTokens!.Value,
            preset.CompactAtTokens!.Value,
            scope);
        ContextPolicy.Validate(plan);
        return plan;
    }

    public static string NormalizeScope(string? scope) =>
        string.Equals(scope, ContextPolicy.BodyAfterPrefixScope, StringComparison.Ordinal)
            ? ContextPolicy.BodyAfterPrefixScope
            : ContextPolicy.TotalScope;

    public static string Format(long value) => value.ToString("N0", CultureInfo.CurrentCulture);

    private static bool TryParseTokenCount(string text, out long value)
    {
        value = 0;
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return false;
        if (trimmed.All(char.IsAsciiDigit))
        {
            return long.TryParse(trimmed, NumberStyles.None, CultureInfo.InvariantCulture, out value);
        }

        foreach (var culture in new[] { CultureInfo.CurrentCulture, CultureInfo.InvariantCulture })
        {
            if (long.TryParse(trimmed, NumberStyles.AllowThousands, culture, out var parsed) &&
                string.Equals(trimmed, parsed.ToString("N0", culture), StringComparison.Ordinal))
            {
                value = parsed;
                return true;
            }
        }
        return false;
    }
}
