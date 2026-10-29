using System.Runtime.InteropServices;

namespace ShowCue.Engine;

/// <summary>Skjermoversikt via Win32 (fysiske piksler), uten å dra inn WinForms.</summary>
public static class Monitors
{
    public sealed record MonitorInfo(int Index, string Name, int Left, int Top, int Width, int Height, bool Primary)
    {
        public override string ToString() => $"Skjerm {Index + 1}: {Width}×{Height}{(Primary ? " (hovedskjerm)" : "")}";
    }

    public static List<MonitorInfo> GetAll()
    {
        var list = new List<MonitorInfo>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr h, IntPtr hdc, ref RECT rect, IntPtr data) =>
        {
            var mi = new MONITORINFOEX { cbSize = Marshal.SizeOf<MONITORINFOEX>() };
            if (GetMonitorInfo(h, ref mi))
            {
                var r = mi.rcMonitor;
                list.Add(new MonitorInfo(list.Count, mi.szDevice, r.left, r.top, r.right - r.left, r.bottom - r.top, (mi.dwFlags & 1) != 0));
            }
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static void PlaceWindow(IntPtr hwnd, MonitorInfo m)
    {
        const uint SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010, SWP_FRAMECHANGED = 0x0020;
        SetWindowPos(hwnd, IntPtr.Zero, m.Left, m.Top, m.Width, m.Height, SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    }

    private delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr data);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int left, top, right, bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX info);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
}
