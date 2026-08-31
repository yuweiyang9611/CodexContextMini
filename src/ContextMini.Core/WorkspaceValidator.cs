namespace ContextMini.Core;

public static class WorkspaceValidator
{
    public static string Normalize(string path) => Normalize(path, static root => new DriveInfo(root).DriveType);

    internal static string Normalize(string path, Func<string, DriveType> driveTypeResolver)
    {
        ArgumentNullException.ThrowIfNull(driveTypeResolver);
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new UnsafeProjectException("Project path is required.");
        }

        string fullPath;
        try
        {
            fullPath = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            throw new UnsafeProjectException($"Project path is invalid: {exception.Message}");
        }

        if (fullPath.StartsWith("\\", StringComparison.Ordinal))
        {
            throw new UnsafeProjectException("UNC/network projects are not supported.");
        }
        var pathRoot = Path.GetPathRoot(fullPath);
        var root = pathRoot?.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (string.IsNullOrEmpty(root) || string.Equals(fullPath, root, StringComparison.OrdinalIgnoreCase))
        {
            throw new UnsafeProjectException("A filesystem root cannot be used as a project.");
        }
        try
        {
            if (driveTypeResolver(pathRoot!) == DriveType.Network)
                throw new UnsafeProjectException("Mapped network-drive projects are not supported.");
        }
        catch (UnsafeProjectException) { throw; }
        catch (Exception exception) when (exception is ArgumentException or IOException or UnauthorizedAccessException)
        {
            throw new UnsafeProjectException($"The project drive could not be validated: {exception.Message}");
        }

        var directory = new DirectoryInfo(fullPath);
        if (!directory.Exists)
        {
            throw new UnsafeProjectException($"Project directory does not exist: {fullPath}");
        }

        for (var cursor = directory; cursor is not null; cursor = cursor.Parent)
        {
            if ((cursor.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new UnsafeProjectException($"Project path contains a reparse point: {cursor.FullName}");
            }
            if (string.Equals(cursor.FullName.TrimEnd(Path.DirectorySeparatorChar), root, StringComparison.OrdinalIgnoreCase))
            {
                break;
            }
        }
        return fullPath;
    }

    public static void RejectReparsePoint(string path, string label)
    {
        if (!File.Exists(path) && !Directory.Exists(path))
        {
            return;
        }
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new UnsafeProjectException($"{label} must not be a reparse point: {path}");
        }
    }
}
