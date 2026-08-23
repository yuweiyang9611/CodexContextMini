using System.Globalization;
using System.Text;

namespace ContextMini.Core;

public sealed class ManagedConfigEditor
{
    public const string MiniBeginMarker = "# >>> codex-context-mini:v1";
    public const string MiniEndMarker = "# <<< codex-context-mini:v1";
    public const string LegacyBeginMarker = "# >>> context-window-manager (managed; use the plugin to edit)";
    public const string LegacyEndMarker = "# <<< context-window-manager";

    private static readonly string[] ManagedKeys =
    [
        "model_context_window",
        "model_auto_compact_token_limit",
        "model_auto_compact_token_limit_scope",
    ];

    public ManagedDocument Analyze(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var newLine = text.Length == 0
            ? Environment.NewLine
            : text.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";
        var miniBegins = Count(text, MiniBeginMarker);
        var miniEnds = Count(text, MiniEndMarker);
        var legacyBegins = Count(text, LegacyBeginMarker);
        var legacyEnds = Count(text, LegacyEndMarker);

        if (miniBegins == 0 && miniEnds == 0 && legacyBegins == 0 && legacyEnds == 0)
        {
            if (text.Contains("codex-context-mini:", StringComparison.Ordinal) ||
                text.Contains("# >>> context-window-manager", StringComparison.Ordinal))
            {
                return Invalid(text, newLine, "An unknown or malformed managed block marker is present.");
            }
            var conflict = FindConflict(text);
            return conflict is null
                ? new ManagedDocument(text, text, newLine, ManagedBlockKind.None, null, null, null, true, null)
                : Invalid(text, newLine, $"A managed context key already exists outside the Mini block: {conflict}");
        }

        if (miniBegins == 1 && miniEnds == 1 && legacyBegins == 0 && legacyEnds == 0)
        {
            return ParseMini(text, newLine);
        }
        if (legacyBegins == 1 && legacyEnds == 1 && miniBegins == 0 && miniEnds == 0)
        {
            return ParseLegacy(text, newLine);
        }
        return Invalid(text, newLine, "Managed block markers are duplicated, mixed, or incomplete.");
    }

    public string Render(ManagedDocument document, ContextPlan plan)
    {
        ArgumentNullException.ThrowIfNull(document);
        ContextPolicy.Validate(plan);
        if (!document.CanWrite)
        {
            throw new ConfigConflictException(document.Warning ?? "The configuration is read-only.");
        }
        if (plan.IsAuto)
        {
            return document.SuffixText;
        }

        var window = plan.WindowTokens!.Value.ToString(CultureInfo.InvariantCulture);
        var compact = plan.CompactAtTokens!.Value.ToString(CultureInfo.InvariantCulture);
        var lines = new[]
        {
            MiniBeginMarker,
            $"model_context_window = {window}",
            $"model_auto_compact_token_limit = {compact}",
            "model_auto_compact_token_limit_scope = \"total\"",
            MiniEndMarker,
        };
        return string.Join(document.NewLine, lines) + document.NewLine + document.SuffixText;
    }

    private static ManagedDocument ParseMini(string text, string newLine)
    {
        if (!text.StartsWith(MiniBeginMarker, StringComparison.Ordinal))
        {
            return Invalid(text, newLine, "The Mini block must be the first TOML content.");
        }
        if (!TryExtract(text, MiniEndMarker, out var block, out var suffix))
        {
            return Invalid(text, newLine, "The Mini block is malformed.");
        }
        var lines = NormalizeLines(block);
        if (lines.Length != 5 || lines[0] != MiniBeginMarker || lines[4] != MiniEndMarker ||
            !TryAssignment(lines[1], "model_context_window", out var windowText) ||
            !TryAssignment(lines[2], "model_auto_compact_token_limit", out var compactText) ||
            !TryAssignment(lines[3], "model_auto_compact_token_limit_scope", out var scopeText) ||
            scopeText != "\"total\"" ||
            !long.TryParse(windowText, NumberStyles.None, CultureInfo.InvariantCulture, out var window) ||
            !long.TryParse(compactText, NumberStyles.None, CultureInfo.InvariantCulture, out var compact))
        {
            return Invalid(text, newLine, "The Mini block contains unexpected content.");
        }
        return FinishParsed(text, suffix, newLine, ManagedBlockKind.MiniV1, window, compact);
    }

    private static ManagedDocument ParseLegacy(string text, string newLine)
    {
        if (!text.StartsWith(LegacyBeginMarker, StringComparison.Ordinal))
        {
            return Invalid(text, newLine, "The legacy managed block must be the first TOML content.");
        }
        if (!TryExtract(text, LegacyEndMarker, out var block, out var suffix))
        {
            return Invalid(text, newLine, "The legacy managed block is malformed.");
        }

        long? window = null;
        long? compact = null;
        string? scope = null;
        foreach (var line in NormalizeLines(block).Skip(1).SkipLast(1))
        {
            if (string.IsNullOrWhiteSpace(line) || line.StartsWith('#'))
            {
                continue;
            }
            if (TryAssignment(line, "model_context_window", out var windowText) &&
                long.TryParse(windowText, NumberStyles.None, CultureInfo.InvariantCulture, out var windowValue))
            {
                if (window is not null) return Invalid(text, newLine, "The legacy block repeats model_context_window.");
                window = windowValue;
            }
            else if (TryAssignment(line, "model_auto_compact_token_limit", out var compactText) &&
                     long.TryParse(compactText, NumberStyles.None, CultureInfo.InvariantCulture, out var compactValue))
            {
                if (compact is not null) return Invalid(text, newLine, "The legacy block repeats model_auto_compact_token_limit.");
                compact = compactValue;
            }
            else if (TryAssignment(line, "model_auto_compact_token_limit_scope", out var scopeText))
            {
                if (scope is not null) return Invalid(text, newLine, "The legacy block repeats compaction scope.");
                scope = scopeText;
            }
            else
            {
                return Invalid(text, newLine, "The legacy managed block contains unexpected content.");
            }
        }
        if (window is null || compact is null || (scope != "\"total\"" && scope != "\"body_after_prefix\""))
        {
            return Invalid(text, newLine, "The legacy managed block is incomplete.");
        }
        return FinishParsed(text, suffix, newLine, ManagedBlockKind.LegacyPlugin, window.Value, compact.Value);
    }

    private static ManagedDocument FinishParsed(
        string text,
        string suffix,
        string newLine,
        ManagedBlockKind kind,
        long window,
        long compact)
    {
        if (kind == ManagedBlockKind.LegacyPlugin)
        {
            if (window <= 0 || compact <= 0 || compact >= window)
            {
                return Invalid(text, newLine, "Legacy managed context values are invalid.");
            }
        }
        else
        {
            try
            {
                ContextPolicy.Validate(window, compact, "total");
            }
            catch (ArgumentException exception)
            {
                return Invalid(text, newLine, $"Managed context values are invalid: {exception.Message}");
            }
        }
        var conflict = FindConflict(suffix);
        return conflict is null
            ? new ManagedDocument(text, suffix, newLine, kind, window, compact, "total", true,
                kind == ManagedBlockKind.LegacyPlugin ? "A legacy plugin block will migrate to Context Mini when applied." : null)
            : Invalid(text, newLine, $"A managed context key exists outside the managed block: {conflict}");
    }

    private static bool TryExtract(string text, string endMarker, out string block, out string suffix)
    {
        var end = text.IndexOf(endMarker, StringComparison.Ordinal);
        if (end < 0)
        {
            block = string.Empty;
            suffix = text;
            return false;
        }
        var after = end + endMarker.Length;
        block = text[..after];
        if (text.AsSpan(after).StartsWith("\r\n")) after += 2;
        else if (text.AsSpan(after).StartsWith("\n")) after += 1;
        suffix = text[after..];
        return true;
    }

    private static string[] NormalizeLines(string text) =>
        text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');

    private static bool TryAssignment(string line, string key, out string value)
    {
        var prefix = key + " = ";
        if (line.StartsWith(prefix, StringComparison.Ordinal))
        {
            value = line[prefix.Length..];
            return true;
        }
        value = string.Empty;
        return false;
    }

    private static string? FindConflict(string text)
    {
        foreach (var rawLine in text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        {
            var line = StripComment(rawLine).Trim();
            if (line.Length == 0) continue;

            string? expression;
            if (line.StartsWith("[[", StringComparison.Ordinal))
            {
                if (!line.EndsWith("]]", StringComparison.Ordinal)) return "unparseable TOML array-table key";
                expression = line[2..^2];
            }
            else if (line.StartsWith("[", StringComparison.Ordinal))
            {
                if (!line.EndsWith("]", StringComparison.Ordinal)) return "unparseable TOML table key";
                expression = line[1..^1];
            }
            else
            {
                var equals = FindUnquotedEquals(line);
                if (equals < 0) continue;
                if (equals == 0) return "unparseable TOML assignment key";
                expression = line[..equals];
            }

            var segments = ParseKeySegments(expression);
            if (segments is null || segments.Count == 0) return "unparseable TOML key";
            foreach (var segment in segments)
            {
                foreach (var managedKey in ManagedKeys)
                {
                    if (string.Equals(segment, managedKey, StringComparison.Ordinal)) return managedKey;
                }
            }
        }
        return null;
    }

    private static string StripComment(string line)
    {
        var quote = '\0';
        var escaped = false;
        for (var index = 0; index < line.Length; index++)
        {
            var character = line[index];
            if (quote == '"' && escaped)
            {
                escaped = false;
                continue;
            }
            if (quote == '"' && character == '\\')
            {
                escaped = true;
                continue;
            }
            if (quote == '\0' && (character == '\'' || character == '"')) quote = character;
            else if (quote != '\0' && character == quote) quote = '\0';
            else if (quote == '\0' && character == '#') return line[..index];
        }
        return line;
    }

    private static List<string>? ParseKeySegments(string expression)
    {
        var segments = new List<string>();
        var index = 0;
        while (true)
        {
            SkipWhitespace(expression, ref index);
            if (index >= expression.Length) return segments.Count == 0 ? null : segments;
            string? segment;
            if (expression[index] == '"') segment = ParseBasicQuotedKey(expression, ref index);
            else if (expression[index] == '\'') segment = ParseLiteralQuotedKey(expression, ref index);
            else segment = ParseBareKey(expression, ref index);
            if (segment is null) return null;
            segments.Add(segment);
            SkipWhitespace(expression, ref index);
            if (index >= expression.Length) return segments;
            if (expression[index] != '.') return null;
            index++;
            if (index >= expression.Length) return null;
        }
    }

    private static string? ParseBareKey(string expression, ref int index)
    {
        var start = index;
        while (index < expression.Length)
        {
            var character = expression[index];
            if (!(char.IsAsciiLetterOrDigit(character) || character is '_' or '-')) break;
            index++;
        }
        return index == start ? null : expression[start..index];
    }

    private static string? ParseLiteralQuotedKey(string expression, ref int index)
    {
        index++;
        var start = index;
        while (index < expression.Length && expression[index] != '\'') index++;
        if (index >= expression.Length) return null;
        var value = expression[start..index];
        index++;
        return value;
    }

    private static string? ParseBasicQuotedKey(string expression, ref int index)
    {
        index++;
        var builder = new StringBuilder();
        while (index < expression.Length)
        {
            var character = expression[index++];
            if (character == '"') return builder.ToString();
            if (character != '\\')
            {
                builder.Append(character);
                continue;
            }
            if (index >= expression.Length) return null;
            var escape = expression[index++];
            switch (escape)
            {
                case '"': builder.Append('"'); break;
                case '\\': builder.Append('\\'); break;
                case 'b': builder.Append('\b'); break;
                case 't': builder.Append('\t'); break;
                case 'n': builder.Append('\n'); break;
                case 'f': builder.Append('\f'); break;
                case 'r': builder.Append('\r'); break;
                case 'u':
                    if (!AppendUnicodeEscape(expression, ref index, 4, builder)) return null;
                    break;
                case 'U':
                    if (!AppendUnicodeEscape(expression, ref index, 8, builder)) return null;
                    break;
                default: return null;
            }
        }
        return null;
    }

    private static bool AppendUnicodeEscape(string expression, ref int index, int length, StringBuilder builder)
    {
        if (index + length > expression.Length) return false;
        if (!int.TryParse(expression.AsSpan(index, length), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var codePoint) ||
            !Rune.IsValid(codePoint)) return false;
        builder.Append(char.ConvertFromUtf32(codePoint));
        index += length;
        return true;
    }

    private static void SkipWhitespace(string expression, ref int index)
    {
        while (index < expression.Length && (expression[index] == ' ' || expression[index] == '\t')) index++;
    }

    private static int FindUnquotedEquals(string line)
    {
        var quote = '\0';
        var escaped = false;
        for (var index = 0; index < line.Length; index++)
        {
            var character = line[index];
            if (quote == '"' && escaped)
            {
                escaped = false;
                continue;
            }
            if (quote == '"' && character == '\\')
            {
                escaped = true;
                continue;
            }
            if (quote == '\0' && (character == '\'' || character == '"')) quote = character;
            else if (quote != '\0' && character == quote) quote = '\0';
            else if (quote == '\0' && character == '=') return index;
        }
        return -1;
    }
    private static int Count(string text, string value)
    {
        var count = 0;
        var offset = 0;
        while ((offset = text.IndexOf(value, offset, StringComparison.Ordinal)) >= 0)
        {
            count++;
            offset += value.Length;
        }
        return count;
    }

    private static ManagedDocument Invalid(string text, string newLine, string warning) =>
        new(text, text, newLine, ManagedBlockKind.None, null, null, null, false, warning);
}
