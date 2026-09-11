namespace ContextMini.Core;

public enum ContextProfile
{
    Auto,
    Compact128K,
    Balanced400K,
    OneMillion,
    Custom,
}

public enum ManagedBlockKind
{
    None,
    MiniV1,
    LegacyPlugin,
}

public sealed record ContextPlan(
    ContextProfile Profile,
    long? WindowTokens,
    long? CompactAtTokens,
    string Scope = "total")
{
    public bool IsAuto => Profile == ContextProfile.Auto;
}

public sealed record ManagedDocument(
    string OriginalText,
    string SuffixText,
    string NewLine,
    ManagedBlockKind BlockKind,
    long? WindowTokens,
    long? CompactAtTokens,
    string? Scope,
    bool CanWrite,
    string? Warning);

public sealed record ConfigSnapshot(
    string ProjectRoot,
    string ConfigPath,
    bool Exists,
    string Fingerprint,
    bool HasUtf8Bom,
    byte[] SourceBytes,
    ManagedDocument Document)
{
    public ConfigurationScope ConfigurationScope { get; init; } = ConfigurationScope.Project;
    public ConfigTarget Target => new(ConfigurationScope, ProjectRoot);
    public bool ManagedBlockPresent => Document.BlockKind != ManagedBlockKind.None;
}

public sealed record ApplyResult(bool Changed, ConfigSnapshot Snapshot);

public sealed class ConfigConflictException(string message) : IOException(message);

public sealed class UnsafeProjectException(string message) : IOException(message);
