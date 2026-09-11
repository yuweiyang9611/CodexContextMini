using System.Reflection;
using System.Text;
using ContextMini.Core;

namespace ContextMini;

internal static class ConfigurationPresentation
{
    private const int ChangeContextCharacters = 2_500;
    private const int MaximumChangedRegionCharacters = 6_000;

    public static string BuildManagedBlockPreview(ConfigSnapshot snapshot, ContextPlan draft)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(draft);

        var rendered = new ManagedConfigEditor().Render(snapshot.Document, draft);
        var before = ExtractManagedPrefix(snapshot.Document.OriginalText, snapshot.Document.SuffixText);
        var after = ExtractManagedPrefix(rendered, snapshot.Document.SuffixText);
        return $"变更前的受管块：\n{DisplayBlock(before)}\n\n" +
               $"变更后的受管块：\n{DisplayBlock(after)}\n\n" +
               "受管块之外的 TOML 内容将保持不变。";
    }

    public static string BuildExternalChangePreview(ConfigSnapshot before, ConfigSnapshot after)
    {
        ArgumentNullException.ThrowIfNull(before);
        ArgumentNullException.ThrowIfNull(after);
        var beforeText = before.Document.OriginalText;
        var afterText = after.Document.OriginalText;
        if (string.Equals(beforeText, afterText, StringComparison.Ordinal))
        {
            var bytesEqual = before.SourceBytes.AsSpan().SequenceEqual(after.SourceBytes);
            var detail = bytesEqual
                ? "配置字节内容相同；检测到的是文件身份变化。"
                : before.HasUtf8Bom != after.HasUtf8Bom
                    ? $"解码后的 TOML 文本相同，但 UTF-8 BOM 已{(after.HasUtf8Bom ? "添加" : "移除")}。"
                    : "解码后的 TOML 文本相同，但底层编码字节发生了变化。";
            return detail + "\n\n" +
                   $"重新加载前 SHA-256：{before.Fingerprint}\n" +
                   $"磁盘最新 SHA-256：{after.Fingerprint}";
        }

        var commonPrefix = 0;
        var prefixLimit = Math.Min(beforeText.Length, afterText.Length);
        while (commonPrefix < prefixLimit && beforeText[commonPrefix] == afterText[commonPrefix])
        {
            commonPrefix++;
        }
        var commonSuffix = 0;
        var suffixLimit = Math.Min(
            beforeText.Length - commonPrefix,
            afterText.Length - commonPrefix);
        while (commonSuffix < suffixLimit &&
               beforeText[^(commonSuffix + 1)] == afterText[^(commonSuffix + 1)])
        {
            commonSuffix++;
        }

        var beforeEnd = beforeText.Length - commonSuffix;
        var afterEnd = afterText.Length - commonSuffix;
        return $"首个差异位于字符偏移 {commonPrefix:N0}；下方始终包含差异区域附近的上下文。\n\n" +
               $"重新加载前（SHA-256 {before.Fingerprint}）：\n" +
               $"{BuildChangeExcerpt(beforeText, commonPrefix, beforeEnd)}\n\n" +
               $"磁盘最新内容（SHA-256 {after.Fingerprint}）：\n" +
               BuildChangeExcerpt(afterText, commonPrefix, afterEnd);
    }

    public static string BuildDiagnostics(
        ConfigSnapshot? snapshot,
        ContextPlan draft,
        bool dirty,
        bool externalConflict,
        string status)
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "unknown";
        var builder = new StringBuilder()
            .AppendLine($"Context Mini: {version}")
            .AppendLine($"OS: {Environment.OSVersion}")
            .AppendLine($"Configuration scope: {snapshot?.ConfigurationScope.ToString() ?? "(none)"}")
            .AppendLine($"Target root: {snapshot?.ProjectRoot ?? "(none)"}")
            .AppendLine($"Config: {snapshot?.ConfigPath ?? "(none)"}")
            .AppendLine($"Config exists: {snapshot?.Exists.ToString() ?? "unknown"}")
            .AppendLine($"Fingerprint: {snapshot?.Fingerprint ?? "(none)"}")
            .AppendLine($"Managed block: {snapshot?.Document.BlockKind.ToString() ?? "unknown"}")
            .AppendLine($"Draft: {DescribePlan(draft)}")
            .AppendLine($"Dirty: {dirty}")
            .AppendLine($"External conflict: {externalConflict}")
            .AppendLine($"Status: {status}");
        return builder.ToString();
    }

    public static string DescribePlan(ContextPlan plan) => plan.IsAuto
        ? "Auto"
        : $"window={plan.WindowTokens}; compact={plan.CompactAtTokens}; scope={plan.Scope}";

    private static string ExtractManagedPrefix(string text, string suffix)
    {
        var prefixLength = Math.Max(0, text.Length - suffix.Length);
        return text[..prefixLength].TrimEnd('\r', '\n');
    }

    private static string DisplayBlock(string value) =>
        string.IsNullOrEmpty(value) ? "（无受管块）" : value;

    private static string BuildChangeExcerpt(string value, int changeStart, int changeEnd)
    {
        var contextStart = Math.Max(0, changeStart - ChangeContextCharacters);
        var contextEnd = Math.Min(value.Length, changeEnd + ChangeContextCharacters);
        var beforeContext = value[contextStart..changeStart];
        var changed = value[changeStart..changeEnd];
        var afterContext = value[changeEnd..contextEnd];

        if (changed.Length > MaximumChangedRegionCharacters)
        {
            var half = MaximumChangedRegionCharacters / 2;
            changed = changed[..half] +
                      $"\n… 变化区域中省略 {changed.Length - MaximumChangedRegionCharacters:N0} 个字符 …\n" +
                      changed[^half..];
        }
        if (changed.Length == 0) changed = "（空；此版本在该位置没有字符）";

        var builder = new StringBuilder();
        if (contextStart > 0) builder.AppendLine($"… 前方省略 {contextStart:N0} 个字符 …");
        builder.Append(beforeContext)
            .AppendLine("\n<<< 变化区域开始 >>>")
            .Append(changed)
            .AppendLine("\n<<< 变化区域结束 >>>")
            .Append(afterContext);
        if (contextEnd < value.Length)
        {
            builder.AppendLine().Append($"… 后方省略 {value.Length - contextEnd:N0} 个字符 …");
        }
        return builder.ToString();
    }
}
