using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace ContextMini.Core;

internal readonly record struct FileSystemIdentity(uint VolumeSerialNumber, ulong FileIndex)
{
    public static FileSystemIdentity Read(string path, bool directory)
    {
        const uint openReparsePoint = 0x00200000;
        const uint backupSemantics = 0x02000000;
        using var handle = CreateFileW(
            path,
            0,
            FileShare.ReadWrite | FileShare.Delete,
            IntPtr.Zero,
            FileMode.Open,
            openReparsePoint | (directory ? backupSemantics : 0),
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            throw new IOException(
                $"Could not open {path} for identity verification.",
                new Win32Exception(Marshal.GetLastWin32Error()));
        }
        if (!GetFileInformationByHandle(handle, out var information))
        {
            throw new IOException(
                $"Could not read the filesystem identity for {path}.",
                new Win32Exception(Marshal.GetLastWin32Error()));
        }
        ValidateHandleAttributes((FileAttributes)information.FileAttributes, directory, path);
        var fileIndex = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;
        return new FileSystemIdentity(information.VolumeSerialNumber, fileIndex);
    }

    internal static void ValidateHandleAttributes(
        FileAttributes attributes,
        bool directory,
        string path)
    {
        if ((attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new IOException($"The opened path is a reparse point: {path}");
        }

        var actualDirectory = (attributes & FileAttributes.Directory) != 0;
        if (actualDirectory != directory)
        {
            var expectedKind = directory ? "directory" : "file";
            var actualKind = actualDirectory ? "directory" : "file";
            throw new IOException(
                $"The opened path changed type; expected a {expectedKind}, but found a {actualKind}: {path}");
        }
    }

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        FileShare shareMode,
        IntPtr securityAttributes,
        FileMode creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file,
        out ByHandleFileInformation information);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeFileTime
    {
        public uint Low;
        public uint High;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public NativeFileTime CreationTime;
        public NativeFileTime LastAccessTime;
        public NativeFileTime LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }
}
