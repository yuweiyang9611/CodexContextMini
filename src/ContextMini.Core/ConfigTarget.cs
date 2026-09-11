namespace ContextMini.Core;

public enum ConfigurationScope
{
    Project,
    Global,
}

/// <summary>A captured location; applying a snapshot never re-resolves CODEX_HOME.</summary>
public sealed record ConfigTarget(ConfigurationScope Scope, string Root)
{
    public bool IsGlobal => Scope == ConfigurationScope.Global;
    public string ConfigDirectory => IsGlobal ? Root : Path.Combine(Root, ".codex");
    public string ConfigPath => Path.Combine(ConfigDirectory, "config.toml");

    public static ConfigTarget ForProject(string root) => new(ConfigurationScope.Project, root);

    public static ConfigTarget GlobalDefault() => ResolveGlobal(
        Environment.GetEnvironmentVariable("CODEX_HOME"),
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));

    public static ConfigTarget ResolveGlobal(string? codexHome, string userProfile)
    {
        if (string.IsNullOrWhiteSpace(codexHome) && !Path.IsPathFullyQualified(userProfile))
            throw new UnsafeProjectException("The user profile directory could not be resolved.");
        var home = string.IsNullOrWhiteSpace(codexHome) ? Path.Combine(userProfile, ".codex") : codexHome;
        if (!Path.IsPathFullyQualified(home))
            throw new UnsafeProjectException("CODEX_HOME must be an absolute local directory path.");
        return new ConfigTarget(ConfigurationScope.Global, Path.TrimEndingDirectorySeparator(Path.GetFullPath(home)));
    }

    public ConfigTarget Normalize()
    {
        if (Scope == ConfigurationScope.Project) return this with { Root = WorkspaceValidator.Normalize(Root) };
        if (Scope != ConfigurationScope.Global || !Path.IsPathFullyQualified(Root))
            throw new UnsafeProjectException("Invalid configuration target.");
        // Validate network/root paths before probing the filesystem. A missing home
        // is allowed only when its parent already exists; browsing never creates it.
        return this with
        {
            Root = WorkspaceValidator.Normalize(Root, static root => new DriveInfo(root).DriveType, allowMissingLeaf: true),
        };
    }
}
