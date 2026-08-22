using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace FileMCP.Core;

public sealed class WindowsCredentialStore
{
    private const string DefaultTargetName = "FileMCP/runtime-api-key";
    private readonly string _targetName;

    public WindowsCredentialStore(string? targetName = null) => _targetName = targetName ?? DefaultTargetName;

    public bool HasSavedApiKey
    {
        get
        {
            try { return !string.IsNullOrEmpty(ReadApiKeyOrNull()); }
            catch { return false; }
        }
    }

    public string ReadApiKey() => ReadApiKeyOrNull() ?? throw new FileMcpException("No API key is saved.");

    public void SaveApiKey(string value)
    {
        if (string.IsNullOrEmpty(value)) return;
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Windows Credential Manager is only available on Windows.");
        var bytes = Encoding.Unicode.GetBytes(value);
        var blob = Marshal.AllocCoTaskMem(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var credential = new NativeMethods.Credential
            {
                Type = NativeMethods.CredTypeGeneric,
                TargetName = _targetName,
                CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = blob,
                Persist = NativeMethods.CredPersistLocalMachine,
                UserName = Environment.UserName,
            };
            if (!NativeMethods.CredWriteW(ref credential, 0)) throw CredentialError("save the API key");
        }
        finally
        {
            Marshal.Copy(new byte[bytes.Length], 0, blob, bytes.Length);
            Marshal.FreeCoTaskMem(blob);
        }
    }

    public void DeleteApiKey()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Windows Credential Manager is only available on Windows.");
        if (NativeMethods.CredDeleteW(_targetName, NativeMethods.CredTypeGeneric, 0)) return;
        var error = Marshal.GetLastWin32Error();
        if (error != NativeMethods.ErrorNotFound) throw CredentialError("delete the API key", error);
    }

    private string? ReadApiKeyOrNull()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Windows Credential Manager is only available on Windows.");
        if (!NativeMethods.CredReadW(_targetName, NativeMethods.CredTypeGeneric, 0, out var pointer))
        {
            var error = Marshal.GetLastWin32Error();
            if (error == NativeMethods.ErrorNotFound) return null;
            throw CredentialError("read the API key", error);
        }
        try
        {
            var credential = Marshal.PtrToStructure<NativeMethods.Credential>(pointer);
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0) return "";
            var bytes = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            return Encoding.Unicode.GetString(bytes);
        }
        finally { NativeMethods.CredFree(pointer); }
    }

    private static FileMcpException CredentialError(string operation, int? code = null)
    {
        var error = code ?? Marshal.GetLastWin32Error();
        return new FileMcpException($"Could not {operation} in Windows Credential Manager: {new Win32Exception(error).Message} (Win32 {error})");
    }

    private static class NativeMethods
    {
        internal const uint CredTypeGeneric = 1;
        internal const uint CredPersistLocalMachine = 2;
        internal const int ErrorNotFound = 1168;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct Credential
        {
            public uint Flags;
            public uint Type;
            [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
            [MarshalAs(UnmanagedType.LPWStr)] public string? Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public uint CredentialBlobSize;
            public IntPtr CredentialBlob;
            public uint Persist;
            public uint AttributeCount;
            public IntPtr Attributes;
            [MarshalAs(UnmanagedType.LPWStr)] public string? TargetAlias;
            [MarshalAs(UnmanagedType.LPWStr)] public string UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CredWriteW([In] ref Credential credential, uint flags);

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CredReadW(string target, uint type, uint reservedFlag, out IntPtr credentialPtr);

        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CredDeleteW(string target, uint type, uint flags);

        [DllImport("advapi32.dll")]
        internal static extern void CredFree(IntPtr buffer);
    }
}
