namespace ContextMini.Core;

public static class WorkspaceValidator
{
    public static string Normalize(string path)
    {
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
        var root = Path.GetPathRoot(fullPath)?.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (string.IsNullOrEmpty(root) || string.Equals(fullPath, root, StringComparison.OrdinalIgnoreCase))
        {
            throw new UnsafeProjectException("A filesystem root cannot be used as a project.");
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
