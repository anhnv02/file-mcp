using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace FileMCP.Core;

internal sealed class SafePathResolver
{
    private readonly string _rootPath;

    public SafePathResolver(string rootPath)
    {
        if (string.IsNullOrWhiteSpace(rootPath))
        {
            throw new FileMcpException("Shared directory cannot be empty.");
        }

        var expanded = Environment.ExpandEnvironmentVariables(rootPath.Trim());
        Directory.CreateDirectory(expanded);
        _rootPath = CanonicalizeExistingPath(Path.GetFullPath(expanded));
        Root = _rootPath;
    }

    public string Root { get; }

    public string Resolve(string relativePath)
    {
        var lexical = LexicalPath(relativePath);
        var canonical = CanonicalizeExistingAncestor(lexical);
        EnsureContained(canonical);
        return canonical;
    }

    public string ResolveForDeletion(string relativePath)
    {
        var lexical = LexicalPath(relativePath);
        if (PathEquals(lexical, _rootPath))
        {
            return _rootPath;
        }

        var parent = Path.GetDirectoryName(lexical)
            ?? throw new FileMcpException("Refused: path is outside the shared directory");
        var canonicalParent = CanonicalizeExistingAncestor(parent);
        EnsureContained(canonicalParent);
        return Path.GetFullPath(Path.Combine(canonicalParent, Path.GetFileName(lexical)));
    }

    public bool Contains(string path)
    {
        try
        {
            var canonical = CanonicalizeExistingAncestor(Path.GetFullPath(path));
            return IsContained(canonical);
        }
        catch
        {
            return false;
        }
    }

    public string RelativePath(string path)
    {
        var canonical = CanonicalizeExistingAncestor(Path.GetFullPath(path));
        EnsureContained(canonical);
        if (PathEquals(canonical, _rootPath))
        {
            return "";
        }
        return Path.GetRelativePath(_rootPath, canonical).Replace('\\', '/');
    }

    public FileAttributes GetAttributesWithoutFollowingFinalTarget(string path, string missingMessage)
    {
        try
        {
            return File.GetAttributes(path);
        }
        catch (FileNotFoundException)
        {
            throw new FileMcpException(missingMessage);
        }
        catch (DirectoryNotFoundException)
        {
            throw new FileMcpException(missingMessage);
        }
        catch (IOException ex)
        {
            throw new FileMcpException($"Could not inspect {Path.GetFileName(path)}: {ex.Message}");
        }
        catch (UnauthorizedAccessException ex)
        {
            throw new FileMcpException($"Could not inspect {Path.GetFileName(path)}: {ex.Message}");
        }
    }

    private string LexicalPath(string relativePath)
    {
        var value = relativePath ?? "";
        if (Path.IsPathRooted(value) || value.StartsWith("\\\\", StringComparison.Ordinal))
        {
            throw new FileMcpException("Refused: path is outside the shared directory");
        }

        var lexical = Path.GetFullPath(Path.Combine(_rootPath, value));
        if (!IsContained(lexical))
        {
            throw new FileMcpException("Refused: path is outside the shared directory");
        }
        return lexical;
    }

    private string CanonicalizeExistingAncestor(string path)
    {
        var current = Path.GetFullPath(path);
        var suffix = new Stack<string>();

        while (!EntryExists(current))
        {
            var parent = Path.GetDirectoryName(current);
            if (string.IsNullOrEmpty(parent) || PathEquals(parent, current))
            {
                break;
            }
            suffix.Push(Path.GetFileName(current));
            current = parent;
        }

        var resolved = EntryExists(current)
            ? CanonicalizeExistingPath(current)
            : Path.GetFullPath(current);
        while (suffix.Count > 0)
        {
            resolved = Path.GetFullPath(Path.Combine(resolved, suffix.Pop()));
        }
        return resolved;
    }

    private static bool EntryExists(string path)
    {
        try
        {
            _ = File.GetAttributes(path);
            return true;
        }
        catch (FileNotFoundException)
        {
            return false;
        }
        catch (DirectoryNotFoundException)
        {
            return false;
        }
    }

    private void EnsureContained(string path)
    {
        if (!IsContained(path))
        {
            throw new FileMcpException("Refused: path is outside the shared directory");
        }
    }

    private bool IsContained(string path)
    {
        var full = TrimDirectorySeparator(Path.GetFullPath(path));
        var root = TrimDirectorySeparator(_rootPath);
        if (PathEquals(full, root))
        {
            return true;
        }
        return full.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private static string CanonicalizeExistingPath(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            return Path.GetFullPath(path);
        }

        using var handle = NativeMethods.CreateFileW(
            path,
            0,
            NativeMethods.FileShareRead | NativeMethods.FileShareWrite | NativeMethods.FileShareDelete,
            IntPtr.Zero,
            NativeMethods.OpenExisting,
            NativeMethods.FileFlagBackupSemantics,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), $"Could not resolve path: {path}");
        }

        var capacity = 1024u;
        while (true)
        {
            var buffer = new char[capacity];
            var length = NativeMethods.GetFinalPathNameByHandleW(handle, buffer, capacity, 0);
            if (length == 0)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), $"Could not resolve path: {path}");
            }
            if (length < capacity)
            {
                return NormalizeFinalPath(new string(buffer, 0, (int)length));
            }
            capacity = length + 1;
        }
    }

    private static string NormalizeFinalPath(string path)
    {
        const string uncPrefix = "\\\\?\\UNC\\";
        const string extendedPrefix = "\\\\?\\";
        if (path.StartsWith(uncPrefix, StringComparison.OrdinalIgnoreCase))
        {
            return "\\\\" + path[uncPrefix.Length..];
        }
        if (path.StartsWith(extendedPrefix, StringComparison.OrdinalIgnoreCase))
        {
            return path[extendedPrefix.Length..];
        }
        return path;
    }

    private static string TrimDirectorySeparator(string path)
    {
        var root = Path.GetPathRoot(path);
        if (root is not null && PathEquals(path, root))
        {
            return path;
        }
        return path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }

    private static bool PathEquals(string lhs, string rhs) =>
        string.Equals(
            TrimForComparison(Path.GetFullPath(lhs)),
            TrimForComparison(Path.GetFullPath(rhs)),
            StringComparison.OrdinalIgnoreCase);

    private static string TrimForComparison(string path) =>
        path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

    private static class NativeMethods
    {
        internal const uint FileShareRead = 0x00000001;
        internal const uint FileShareWrite = 0x00000002;
        internal const uint FileShareDelete = 0x00000004;
        internal const uint OpenExisting = 3;
        internal const uint FileFlagBackupSemantics = 0x02000000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern uint GetFinalPathNameByHandleW(
            SafeFileHandle file,
            [Out] char[] filePath,
            uint filePathSize,
            uint flags);
    }
}
