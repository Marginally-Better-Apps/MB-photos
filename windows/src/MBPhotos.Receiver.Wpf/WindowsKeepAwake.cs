using System.Runtime.InteropServices;

namespace MBPhotos.Receiver.Wpf;

internal sealed class WindowsKeepAwake : IDisposable
{
    private bool disposed;

    public WindowsKeepAwake()
    {
        _ = SetThreadExecutionState(ExecutionState.Continuous | ExecutionState.SystemRequired | ExecutionState.DisplayRequired);
    }

    public void Dispose()
    {
        if (!disposed)
        {
            _ = SetThreadExecutionState(ExecutionState.Continuous);
            disposed = true;
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern ExecutionState SetThreadExecutionState(ExecutionState executionState);

    [Flags]
    private enum ExecutionState : uint
    {
        SystemRequired = 0x00000001,
        DisplayRequired = 0x00000002,
        Continuous = 0x80000000,
    }
}
