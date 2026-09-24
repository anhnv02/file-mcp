using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace FileMCP.Core;

// The tunnel polls the control plane, so idle system sleep (e.g. a locked screen) takes it
// offline. A power request keeps the system awake while connected; the display may still sleep.
// Unlike SetThreadExecutionState it is tied to a handle, not to the calling thread.
internal sealed class SystemSleepGuard : IDisposable
{
    private SafeFileHandle? _request;

    public bool IsActive => _request is not null;

    public void Acquire()
    {
        if (_request is not null) return;
        var context = new NativeMethods.ReasonContext
        {
            Version = NativeMethods.PowerRequestContextVersion,
            Flags = NativeMethods.PowerRequestContextSimpleString,
            SimpleReasonString = "FileMCP tunnel is connected",
        };
        var request = NativeMethods.PowerCreateRequest(ref context);
        if (request.IsInvalid) { request.Dispose(); return; }
        if (!NativeMethods.PowerSetRequest(request, NativeMethods.PowerRequestSystemRequired)) { request.Dispose(); return; }
        _request = request;
    }

    public void Release()
    {
        var request = _request;
        if (request is null) return;
        _request = null;
        NativeMethods.PowerClearRequest(request, NativeMethods.PowerRequestSystemRequired);
        request.Dispose();
    }

    public void Dispose() => Release();

    private static class NativeMethods
    {
        internal const uint PowerRequestContextVersion = 0;
        internal const uint PowerRequestContextSimpleString = 0x1;
        internal const int PowerRequestSystemRequired = 1;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct ReasonContext
        {
            public uint Version;
            public uint Flags;
            [MarshalAs(UnmanagedType.LPWStr)] public string SimpleReasonString;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern SafeFileHandle PowerCreateRequest(ref ReasonContext context);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool PowerSetRequest(SafeFileHandle powerRequest, int requestType);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool PowerClearRequest(SafeFileHandle powerRequest, int requestType);
    }
}
