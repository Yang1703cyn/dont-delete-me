# ============================================================================
# 未经运行。
# 这个文件是在一台 Mac 上写的，没有在任何 Windows 电脑上运行过、也没有编译过，只做过人工通读和一次独立审阅。
# 第一次运行如果在"Add-Type"这一步报编译错误，请把报错原文交给负责 Windows 版的人。
# ============================================================================
#
# 「别删我」Windows 探针脚本的公共部分：其它脚本用  . "$PSScriptRoot\common.ps1"  把它读进来。
#
# 它做什么：用一段内嵌的 C# 代码，经系统公开的接口向资源管理器（Explorer）的桌面视图询问图标的位置等信息，
#           并提供几个查看窗口、鼠标状态的小工具。
# 它不做什么：不注入、不读写别的进程的内存、不装钩子、不改任何系统设置、不移动任何图标、
#             不读取你的任何文件的内容、不联网。图标的名字只在内存里用来比对，不打印、不保存。
# 顺带的副作用：Add-Type 编译内嵌的 C# 时，会在系统临时文件夹里写下并删掉几个编译用的临时文件；
#               为了正确显示中文，会把这个控制台窗口的输出编码改成 UTF-8（跑完关掉这个窗口即可恢复）。
#
# 运行环境：Windows 10 / 11 自带的 Windows PowerShell 5.1（powershell.exe），不需要安装任何东西。
# 文件编码：UTF-8 带签名（BOM）。Windows PowerShell 5.1 靠这个签名识别中文，请不要用会去掉签名的工具转存。

$ErrorActionPreference = 'Stop'

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

if ($PSVersionTable.PSVersion.Major -ge 6) {
    Write-Warning '这些脚本是为 Windows PowerShell 5.1（powershell.exe）写的；在 PowerShell 7（pwsh）里内嵌的 C# 可能编译不过。'
}
if ([System.Threading.Thread]::CurrentThread.GetApartmentState().ToString() -ne 'STA') {
    Write-Warning '当前线程不是 STA。请用  powershell -NoProfile -STA -ExecutionPolicy Bypass -File <脚本>  运行。'
}

if (-not ('DdmProbe.DesktopView' -as [type])) {
    # 下一行是内嵌 C# 的开头：C# 的第 1 行 = 本文件的第（这个数 + 1）行。编译出错时用它换算行号
    $ddmSourceLineOffset = (Get-PSCallStack)[0].ScriptLineNumber + 1
    $ddmProbeSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace DdmProbe
{
    // ---------------------------------------------------------------- 基本结构

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct SHFILEINFO
    {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)]
        public string szTypeName;
    }

    // shellapi.h 在 32 位下按 1 字节对齐、64 位下按默认对齐，所以两种位数各用一个结构。
    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    internal struct SHQUERYRBINFO64
    {
        public int cbSize;
        public long i64Size;
        public long i64NumItems;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    internal struct SHQUERYRBINFO32
    {
        public int cbSize;
        public long i64Size;
        public long i64NumItems;
    }

    // ---------------------------------------------------------------- 系统函数

    internal static class Native
    {
        [DllImport("user32.dll")]
        public static extern bool GetCursorPos(out POINT pt);

        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int vKey);

        [DllImport("user32.dll")]
        public static extern IntPtr WindowFromPoint(POINT pt);

        [DllImport("user32.dll")]
        public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassName(IntPtr hwnd, StringBuilder className, int maxCount);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hwnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowTitle);

        [DllImport("user32.dll")]
        public static extern bool ClientToScreen(IntPtr hwnd, ref POINT pt);

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern IntPtr GetShellWindow();

        [DllImport("user32.dll")]
        public static extern IntPtr GetWindow(IntPtr hwnd, uint command);

        [DllImport("user32.dll")]
        public static extern IntPtr GetTopWindow(IntPtr hwnd);

        [DllImport("user32.dll")]
        public static extern int GetSystemMetrics(int index);

        [DllImport("user32.dll")]
        public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

        [DllImport("user32.dll")]
        public static extern IntPtr MonitorFromPoint(POINT pt, uint flags);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
        public static extern int GetWindowLong(IntPtr hwnd, int index);

        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
        public static extern IntPtr SetWindowLongPtr64(IntPtr hwnd, int index, IntPtr value);

        [DllImport("user32.dll", EntryPoint = "SetWindowLongW")]
        public static extern int SetWindowLong32(IntPtr hwnd, int index, int value);

        [DllImport("shcore.dll")]
        public static extern int GetDpiForMonitor(IntPtr monitor, int dpiType, out uint dpiX, out uint dpiY);

        [DllImport("dwmapi.dll")]
        public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);

        [DllImport("shell32.dll", EntryPoint = "SHGetFileInfoW", CharSet = CharSet.Unicode)]
        public static extern IntPtr SHGetFileInfo(IntPtr pidl, uint fileAttributes, ref SHFILEINFO info, uint infoSize, uint flags);

        [DllImport("shell32.dll")]
        public static extern int SHGetNameFromIDList(IntPtr pidl, uint sigdn, out IntPtr name);

        [DllImport("shell32.dll")]
        public static extern int SHGetKnownFolderIDList(ref Guid folderId, uint flags, IntPtr token, out IntPtr pidl);

        [DllImport("shell32.dll", EntryPoint = "SHQueryRecycleBinW", CharSet = CharSet.Unicode)]
        public static extern int SHQueryRecycleBin64(string rootPath, ref SHQUERYRBINFO64 info);

        [DllImport("shell32.dll", EntryPoint = "SHQueryRecycleBinW", CharSet = CharSet.Unicode)]
        public static extern int SHQueryRecycleBin32(string rootPath, ref SHQUERYRBINFO32 info);

        [DllImport("shell32.dll")]
        public static extern int SHQueryUserNotificationState(out int state);
    }

    // ---------------------------------------------------------------- 组件对象接口
    // 只声明用得到的方法；排在它们前面的方法必须按头文件里的次序逐个占位（签名无所谓，因为从不调用）。

    // 双重接口，按虚表调用：IDispatch 的 4 个方法由运行时自动补上，后面按 exdisp.h 的次序逐个占位，第 9 个是 FindWindowSW。
    [ComImport, Guid("85CB6900-4D95-11CF-960C-0080C7F4EE85"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    internal interface IShellWindows
    {
        [PreserveSig] int get_Count(out int count);
        [PreserveSig] int Item(IntPtr placeholder1, IntPtr placeholder2, IntPtr placeholder3, out IntPtr folder);
        [PreserveSig] int _NewEnum(out IntPtr enumerator);
        [PreserveSig] int Register(IntPtr dispatch, int hwnd, int windowClass, out int cookie);
        [PreserveSig] int RegisterPending(int threadId, IntPtr location, IntPtr locationRoot, int windowClass, out int cookie);
        [PreserveSig] int Revoke(int cookie);
        [PreserveSig] int OnNavigate(int cookie, IntPtr location);
        [PreserveSig] int OnActivated(int cookie, short active);
        [PreserveSig] int FindWindowSW(
            [MarshalAs(UnmanagedType.Struct)] ref object location,
            [MarshalAs(UnmanagedType.Struct)] ref object locationRoot,
            int windowClass,
            out int hwnd,
            int options,
            [MarshalAs(UnmanagedType.IDispatch)] out object dispatch);
    }

    [ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IOleServiceProvider
    {
        [PreserveSig]
        int QueryService(ref Guid service, ref Guid interfaceId, [MarshalAs(UnmanagedType.IUnknown)] out object result);
    }

    [ComImport, Guid("000214E2-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellBrowser
    {
        // IOleWindow
        [PreserveSig] int GetWindow(out IntPtr hwnd);
        [PreserveSig] int ContextSensitiveHelp(int enterMode);
        // IShellBrowser
        [PreserveSig] int InsertMenusSB(IntPtr a, IntPtr b);
        [PreserveSig] int SetMenuSB(IntPtr a, IntPtr b, IntPtr c);
        [PreserveSig] int RemoveMenusSB(IntPtr a);
        [PreserveSig] int SetStatusTextSB(IntPtr a);
        [PreserveSig] int EnableModelessSB(int a);
        [PreserveSig] int TranslateAcceleratorSB(IntPtr a, short b);
        [PreserveSig] int BrowseObject(IntPtr a, uint b);
        [PreserveSig] int GetViewStateStream(uint a, out IntPtr b);
        [PreserveSig] int GetControlWindow(uint a, out IntPtr b);
        [PreserveSig] int SendControlMsg(uint a, uint b, IntPtr c, IntPtr d, out IntPtr e);
        [PreserveSig] int QueryActiveShellView([MarshalAs(UnmanagedType.IUnknown)] out object view);
    }

    [ComImport, Guid("000214E3-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellView
    {
        // IOleWindow
        [PreserveSig] int GetWindow(out IntPtr hwnd);
        [PreserveSig] int ContextSensitiveHelp(int enterMode);
        // IShellView
        [PreserveSig] int TranslateAccelerator(IntPtr message);
        [PreserveSig] int EnableModeless(int enable);
        [PreserveSig] int UIActivate(uint state);
        [PreserveSig] int Refresh();
        [PreserveSig] int CreateViewWindow(IntPtr previous, IntPtr settings, IntPtr browser, IntPtr rect, out IntPtr hwnd);
        [PreserveSig] int DestroyViewWindow();
        [PreserveSig] int GetCurrentInfo(IntPtr settings);
        [PreserveSig] int AddPropertySheetPages(uint reserved, IntPtr callback, IntPtr lparam);
        [PreserveSig] int SaveViewState();
        [PreserveSig] int SelectItem(IntPtr pidl, uint flags);
        [PreserveSig] int GetItemObject(uint item, ref Guid interfaceId, [MarshalAs(UnmanagedType.IUnknown)] out object result);
    }

    [ComImport, Guid("CDE725B0-CCC9-4519-917E-325D72FAB4CE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFolderView
    {
        [PreserveSig] int GetCurrentViewMode(out uint viewMode);
        [PreserveSig] int SetCurrentViewMode(uint viewMode);
        [PreserveSig] int GetFolder(ref Guid interfaceId, [MarshalAs(UnmanagedType.IUnknown)] out object folder);
        [PreserveSig] int Item(int index, out IntPtr pidl);
        [PreserveSig] int ItemCount(uint flags, out int count);
        [PreserveSig] int Items(uint flags, ref Guid interfaceId, [MarshalAs(UnmanagedType.IUnknown)] out object items);
        [PreserveSig] int GetSelectionMarkedItem(out int index);
        [PreserveSig] int GetFocusedItem(out int index);
        [PreserveSig] int GetItemPosition(IntPtr pidl, out POINT position);
        [PreserveSig] int GetSpacing(out POINT spacing);
        [PreserveSig] int GetDefaultSpacing(out POINT spacing);
        [PreserveSig] int GetAutoArrange();
        [PreserveSig] int SelectItem(int index, uint flags);
        [PreserveSig] int SelectAndPositionItems(uint count, IntPtr pidls, IntPtr points, uint flags);
    }

    // IFolderView2 继承 IFolderView：先把上面 14 个方法原样重复一遍，再接它自己的方法。
    [ComImport, Guid("1AF3A467-214F-4298-908E-06B03E0B39F9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFolderView2
    {
        // IFolderView
        [PreserveSig] int GetCurrentViewMode(out uint viewMode);
        [PreserveSig] int SetCurrentViewMode(uint viewMode);
        [PreserveSig] int GetFolder(ref Guid interfaceId, [MarshalAs(UnmanagedType.IUnknown)] out object folder);
        [PreserveSig] int Item(int index, out IntPtr pidl);
        [PreserveSig] int ItemCount(uint flags, out int count);
        [PreserveSig] int Items(uint flags, ref Guid interfaceId, [MarshalAs(UnmanagedType.IUnknown)] out object items);
        [PreserveSig] int GetSelectionMarkedItem(out int index);
        [PreserveSig] int GetFocusedItem(out int index);
        [PreserveSig] int GetItemPosition(IntPtr pidl, out POINT position);
        [PreserveSig] int GetSpacing(out POINT spacing);
        [PreserveSig] int GetDefaultSpacing(out POINT spacing);
        [PreserveSig] int GetAutoArrange();
        [PreserveSig] int SelectItem(int index, uint flags);
        [PreserveSig] int SelectAndPositionItems(uint count, IntPtr pidls, IntPtr points, uint flags);
        // IFolderView2（前 8 个只占位）
        [PreserveSig] int SetGroupBy(IntPtr key, int ascending);
        [PreserveSig] int GetGroupBy(IntPtr key, IntPtr ascending);
        [PreserveSig] int SetViewProperty(IntPtr pidl, IntPtr key, IntPtr value);
        [PreserveSig] int GetViewProperty(IntPtr pidl, IntPtr key, IntPtr value);
        [PreserveSig] int SetTileViewProperties(IntPtr pidl, IntPtr list);
        [PreserveSig] int SetExtendedTileViewProperties(IntPtr pidl, IntPtr list);
        [PreserveSig] int SetText(int type, IntPtr text);
        [PreserveSig] int SetCurrentFolderFlags(uint mask, uint flags);
        [PreserveSig] int GetCurrentFolderFlags(out uint flags);
        // 再占 10 个位
        [PreserveSig] int GetSortColumnCount(out int count);
        [PreserveSig] int SetSortColumns(IntPtr columns, int count);
        [PreserveSig] int GetSortColumns(IntPtr columns, int count);
        [PreserveSig] int GetItem(int index, ref Guid interfaceId, out IntPtr result);
        [PreserveSig] int GetVisibleItem(int start, int previous, out int index);
        [PreserveSig] int GetSelectedItem(int start, out int index);
        [PreserveSig] int GetSelection(int noneImpliesFolder, out IntPtr items);
        [PreserveSig] int GetSelectionState(IntPtr pidl, out uint flags);
        [PreserveSig] int InvokeVerbOnSelection(IntPtr verb);
        [PreserveSig] int SetViewModeAndIconSize(int viewMode, int iconSize);
        [PreserveSig] int GetViewModeAndIconSize(out int viewMode, out int iconSize);
    }

    [ComImport, Guid("A5CD92FF-29BE-454C-8D04-D82879FB3F1B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IVirtualDesktopManager
    {
        [PreserveSig] int IsWindowOnCurrentVirtualDesktop(IntPtr topLevelWindow, out int onCurrentDesktop);
        [PreserveSig] int GetWindowDesktopId(IntPtr topLevelWindow, out Guid desktopId);
        [PreserveSig] int MoveWindowToDesktop(IntPtr topLevelWindow, ref Guid desktopId);
    }

    // ---------------------------------------------------------------- 一个图标

    public sealed class IconInfo
    {
        public int Index;
        public int RawX;            // GetItemPosition 的原始读数
        public int RawY;
        public int ScreenX;         // 用列表窗口换算成屏幕坐标之后
        public int ScreenY;
        public int PositionResult;  // GetItemPosition 的返回码，0 表示成功
        public bool HasDetails;
        public bool IsFolder;
        public bool IsLink;
        public bool IsFileSystem;
        public bool IsStream;       // 带数据流：zip 这类"能当文件夹打开的文件"靠它认成文件
        public bool IsRecycleBin;
        internal string ParsingName;  // 只在内存里比对用。故意不公开，免得 PowerShell 的默认显示把它打印出来

        /// 解析名（对文件来说就是完整路径）。只用来比对，不要打印。
        public string NameForCompare()
        {
            return ParsingName;
        }

        public string KindText()
        {
            if (!HasDetails) return "未读";
            if (IsRecycleBin) return "回收站";
            if (!IsFileSystem) return "系统图标";
            if (IsLink) return "快捷方式";
            if (IsFolder) return "文件夹";
            return "文件";
        }
    }

    // ---------------------------------------------------------------- 桌面视图

    public sealed class DesktopView
    {
        private IShellView shellView;
        private IFolderView folderView;
        private IFolderView2 folderView2;

        public IntPtr BrowserWindow;   // IShellBrowser::GetWindow
        public IntPtr ViewWindow;      // IShellView::GetWindow（预期类名 SHELLDLL_DefView）
        public IntPtr ListWindow;      // 视图窗口里的列表控件（预期类名 SysListView32）
        public IntPtr RootWindow;      // 视图窗口所在的顶层窗口（预期类名 Progman 或 WorkerW）

        /// 让当前线程按"每显示器 V2"看坐标（Windows 10 1607 起）。更老的系统上什么都不做。
        public static void UsePerMonitorDpi()
        {
            try { Native.SetThreadDpiAwarenessContext(new IntPtr(-4)); }
            catch (Exception) { }
        }

        private static void Check(int result, string what)
        {
            if (result < 0)
            {
                throw new COMException(what + " 失败，返回 0x" + result.ToString("X8"), result);
            }
        }

        private static object FindDesktopDispatch()
        {
            Type type = Type.GetTypeFromCLSID(new Guid("9BA05972-F6A8-11CF-A442-00A0C90A8F39"));
            object shellWindows = Activator.CreateInstance(type);
            object location = 0;      // CSIDL_DESKTOP
            object root = null;       // 空的 VARIANT
            int hwnd;
            object found = null;
            try
            {
                // 8 = SWC_DESKTOP，1 = SWFO_NEEDDISPATCH
                int result = ((IShellWindows)shellWindows).FindWindowSW(ref location, ref root, 8, out hwnd, 1, out found);
                if (result >= 0 && found != null) return found;
            }
            catch (Exception)
            {
                found = null;
            }
            {
                // 备用：经 IDispatch 按名字后期绑定
                object[] args = new object[] { 0, null, 8, 0, 1 };
                ParameterModifier modifier = new ParameterModifier(5);
                modifier[3] = true;   // 只有 phwnd 是传出参数；前两个 VARIANT* 由 IDispatch 自己取地址
                return shellWindows.GetType().InvokeMember(
                    "FindWindowSW", BindingFlags.InvokeMethod, null, shellWindows, args,
                    new ParameterModifier[] { modifier }, null, null);
            }
        }

        public static DesktopView Open()
        {
            UsePerMonitorDpi();
            object dispatch = FindDesktopDispatch();
            if (dispatch == null)
            {
                throw new InvalidOperationException("FindWindowSW 没有找到桌面（资源管理器可能没在运行）");
            }
            IOleServiceProvider provider = (IOleServiceProvider)dispatch;
            Guid service = new Guid("4C96BE40-915C-11CF-99D3-00AA004AE837");   // SID_STopLevelBrowser
            Guid browserId = typeof(IShellBrowser).GUID;
            object browserObject;
            Check(provider.QueryService(ref service, ref browserId, out browserObject), "QueryService(SID_STopLevelBrowser)");
            IShellBrowser browser = (IShellBrowser)browserObject;
            object viewObject;
            Check(browser.QueryActiveShellView(out viewObject), "QueryActiveShellView");

            DesktopView view = new DesktopView();
            view.shellView = (IShellView)viewObject;
            view.folderView = (IFolderView)viewObject;
            view.folderView2 = viewObject as IFolderView2;

            IntPtr handle;
            if (browser.GetWindow(out handle) >= 0) view.BrowserWindow = handle;
            if (view.shellView.GetWindow(out handle) >= 0) view.ViewWindow = handle;
            if (view.ViewWindow != IntPtr.Zero)
            {
                view.ListWindow = Native.FindWindowEx(view.ViewWindow, IntPtr.Zero, "SysListView32", null);
                view.RootWindow = Native.GetAncestor(view.ViewWindow, 2);   // GA_ROOT
            }
            return view;
        }

        public bool HasFolderView2
        {
            get { return folderView2 != null; }
        }

        /// 图标个数（SVGIO_ALLVIEW）。一次进程外调用。
        public int ItemCount()
        {
            int count;
            Check(folderView.ItemCount(2, out count), "ItemCount");
            return count;
        }

        private static string RecycleBinParsingName()
        {
            Guid id = new Guid("B7534046-3ECB-4C18-BE4E-64CD4CB7D6AC");   // FOLDERID_RecycleBinFolder
            IntPtr pidl;
            if (Native.SHGetKnownFolderIDList(ref id, 0, IntPtr.Zero, out pidl) < 0 || pidl == IntPtr.Zero) return null;
            try { return ParsingNameOf(pidl); }
            finally { Marshal.FreeCoTaskMem(pidl); }
        }

        private static string ParsingNameOf(IntPtr pidl)
        {
            IntPtr text;
            // 0x80028000 = SIGDN_DESKTOPABSOLUTEPARSING
            if (Native.SHGetNameFromIDList(pidl, 0x80028000, out text) < 0 || text == IntPtr.Zero) return null;
            try { return Marshal.PtrToStringUni(text); }
            finally { Marshal.FreeCoTaskMem(text); }
        }

        /// 读出所有图标。withDetails 为 false 时只读位置（每个图标两次进程外调用）；
        /// 为 true 时另外在本进程里查种类和解析名（解析名只用于比对）。
        public List<IconInfo> ReadIcons(bool withDetails)
        {
            List<IconInfo> result = new List<IconInfo>();
            int count = ItemCount();
            string recycleBin = withDetails ? RecycleBinParsingName() : null;
            for (int i = 0; i < count; i++)
            {
                IntPtr pidl;
                if (folderView.Item(i, out pidl) < 0 || pidl == IntPtr.Zero) continue;
                try
                {
                    IconInfo info = new IconInfo();
                    info.Index = i;
                    POINT position;
                    info.PositionResult = folderView.GetItemPosition(pidl, out position);
                    info.RawX = position.X;
                    info.RawY = position.Y;
                    POINT onScreen = position;
                    if (ListWindow != IntPtr.Zero) Native.ClientToScreen(ListWindow, ref onScreen);
                    info.ScreenX = onScreen.X;
                    info.ScreenY = onScreen.Y;

                    if (withDetails)
                    {
                        info.HasDetails = true;
                        info.ParsingName = ParsingNameOf(pidl);
                        SHFILEINFO fileInfo = new SHFILEINFO();
                        // 只问四个属性：文件夹 0x20000000、快捷方式 0x00010000、文件系统 0x40000000、流 0x00400000
                        fileInfo.dwAttributes = 0x20000000 | 0x00010000 | 0x40000000 | 0x00400000;
                        // 0x8 = SHGFI_PIDL，0x800 = SHGFI_ATTRIBUTES，0x20000 = SHGFI_ATTR_SPECIFIED
                        IntPtr ok = Native.SHGetFileInfo(pidl, 0, ref fileInfo, (uint)Marshal.SizeOf(typeof(SHFILEINFO)), 0x8 | 0x800 | 0x20000);
                        if (ok != IntPtr.Zero)
                        {
                            info.IsStream = (fileInfo.dwAttributes & 0x00400000) != 0;
                            info.IsFolder = (fileInfo.dwAttributes & 0x20000000) != 0 && !info.IsStream;
                            info.IsLink = (fileInfo.dwAttributes & 0x00010000) != 0;
                            info.IsFileSystem = (fileInfo.dwAttributes & 0x40000000) != 0;
                        }
                        info.IsRecycleBin = recycleBin != null && info.ParsingName != null
                            && string.Equals(recycleBin, info.ParsingName, StringComparison.OrdinalIgnoreCase);
                    }
                    result.Add(info);
                }
                finally
                {
                    Marshal.FreeCoTaskMem(pidl);
                }
            }
            return result;
        }

        /// 返回 { 返回码, 格子宽, 格子高 }。
        public int[] Spacing()
        {
            POINT spacing;
            int result = folderView.GetSpacing(out spacing);
            return new int[] { result, spacing.X, spacing.Y };
        }

        /// 返回 { 返回码, 视图模式, 图标边长（像素） }。没有 IFolderView2 时返回码为 -1。
        public int[] ViewModeAndIconSize()
        {
            if (folderView2 == null) return new int[] { -1, 0, 0 };
            int mode;
            int size;
            int result = folderView2.GetViewModeAndIconSize(out mode, out size);
            return new int[] { result, mode, size };
        }

        /// 返回 { 返回码, 标志位 }。没有 IFolderView2 时返回码为 -1。
        public long[] FolderFlags()
        {
            if (folderView2 == null) return new long[] { -1, 0 };
            uint flags;
            int result = folderView2.GetCurrentFolderFlags(out flags);
            return new long[] { result, flags };
        }

        /// 0 = 开着自动排列，1 = 关着，负数 = 失败。
        public int AutoArrange()
        {
            return folderView.GetAutoArrange();
        }

        /// 桌面视图的自动化对象（经 IDispatch 用，脚本里可以直接读 .FolderFlags、.IconSize、.CurrentViewMode）。
        /// 用来和上面两个方法的读数互相印证。取不到时返回 null。
        public object AutomationObject()
        {
            Guid dispatchId = new Guid("00020400-0000-0000-C000-000000000046");
            object result;
            if (shellView.GetItemObject(0, ref dispatchId, out result) < 0) return null;   // 0 = SVGIO_BACKGROUND
            return result;
        }

        public bool ListWindowVisible()
        {
            return ListWindow != IntPtr.Zero && Native.IsWindowVisible(ListWindow);
        }
    }

    // ---------------------------------------------------------------- 窗口与鼠标的小工具

    public static class WindowInfo
    {
        public static string ClassOf(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return "(无)";
            StringBuilder text = new StringBuilder(256);
            Native.GetClassName(hwnd, text, text.Capacity);
            return text.ToString();
        }

        private static readonly uint OwnProcessId = (uint)Process.GetCurrentProcess().Id;
        private static readonly Dictionary<uint, string> OwnerCache = new Dictionary<uint, string>();

        /// "本进程" / "explorer" / "powershell"（另一个 PowerShell，例如同时运行的 03 号探针）/ "其它进程"。不返回别的程序的名字。
        public static string OwnerOf(IntPtr hwnd)
        {
            uint processId;
            Native.GetWindowThreadProcessId(hwnd, out processId);
            if (processId == OwnProcessId) return "本进程";
            lock (OwnerCache)
            {
                string cached;
                if (OwnerCache.TryGetValue(processId, out cached)) return cached;
            }
            string owner = "其它进程";
            try
            {
                using (Process process = Process.GetProcessById((int)processId))
                {
                    if (string.Equals(process.ProcessName, "explorer", StringComparison.OrdinalIgnoreCase)) owner = "explorer";
                    else if (string.Equals(process.ProcessName, "powershell", StringComparison.OrdinalIgnoreCase)) owner = "powershell";
                }
            }
            catch (Exception) { }
            lock (OwnerCache) { OwnerCache[processId] = owner; }
            return owner;
        }

        public static bool IsDesktopRoot(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return false;
            string name = ClassOf(hwnd);
            return (name == "Progman" || name == "WorkerW") && OwnerOf(hwnd) == "explorer";
        }

        /// 一句话说明某个窗口是什么。不含窗口标题。
        public static string Category(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return "查不出来";
            string name = ClassOf(hwnd);
            // 控制台窗口报告的所属进程是在里面运行的程序（往往是另一个 PowerShell），先单独认出来，免得和 03 的叠加窗口混在一起
            if (name == "ConsoleWindowClass") return "控制台窗口（ConsoleWindowClass）";
            string owner = OwnerOf(hwnd);
            if (owner == "本进程") return "本进程的窗口（" + name + "）";
            if (owner == "powershell") return "另一个 PowerShell 进程的窗口（" + name + "；同时运行的 03 号探针的叠加窗口会归到这一类）";
            if (owner == "explorer")
            {
                string parent = ClassOf(Native.GetAncestor(hwnd, 1));   // GA_PARENT
                string root = ClassOf(Native.GetAncestor(hwnd, 2));     // GA_ROOT
                if (name == "SysListView32" && parent == "SHELLDLL_DefView")
                {
                    return "桌面图标层（SysListView32 ← SHELLDLL_DefView ← 顶层 " + root + "）";
                }
                return "资源管理器的其它窗口（" + name + "，顶层 " + root + "）";
            }
            return "别的程序的窗口";
        }

        /// 某个屏幕坐标上，WindowFromPoint 给出的窗口是什么。
        public static string SurfaceAt(int x, int y)
        {
            POINT point;
            point.X = x;
            point.Y = y;
            return Category(Native.WindowFromPoint(point));
        }

        /// 从最上面数起，hwnd 是第几个顶层窗口；找不到返回 -1。
        public static int ZIndexOf(IntPtr hwnd)
        {
            int index = 0;
            IntPtr current = Native.GetTopWindow(IntPtr.Zero);
            while (current != IntPtr.Zero && index < 5000)
            {
                if (current == hwnd) return index;
                current = Native.GetWindow(current, 2);   // GW_HWNDNEXT
                index++;
            }
            return -1;
        }

        /// hwnd 之上有几个"可见、没有被系统隐藏到别的虚拟桌面"的顶层窗口。找不到 hwnd 返回 -1。
        public static int VisibleWindowsAbove(IntPtr hwnd)
        {
            int visible = 0;
            int guard = 0;
            IntPtr current = Native.GetTopWindow(IntPtr.Zero);
            while (current != IntPtr.Zero && guard < 5000)
            {
                if (current == hwnd) return visible;
                if (Native.IsWindowVisible(current))
                {
                    int cloaked = 0;
                    try { Native.DwmGetWindowAttribute(current, 14, out cloaked, 4); }   // 14 = DWMWA_CLOAKED
                    catch (Exception) { cloaked = 0; }
                    if (cloaked == 0) visible++;
                }
                current = Native.GetWindow(current, 2);
                guard++;
            }
            return -1;
        }

        public static IntPtr Foreground()
        {
            return Native.GetForegroundWindow();
        }

        /// 系统给出的桌面窗口（GetShellWindow）的类名。
        public static string ShellWindowClass()
        {
            return ClassOf(Native.GetShellWindow());
        }

        /// 系统给出的桌面窗口是不是直接含有 SHELLDLL_DefView（装着桌面图标的视图窗口）。
        public static bool ShellWindowHasDefView()
        {
            IntPtr shell = Native.GetShellWindow();
            return shell != IntPtr.Zero && Native.FindWindowEx(shell, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero;
        }

        /// 本脚本自己的控制台窗口里有没有按过 Esc。只读本控制台的输入缓冲，不是钩子，读不到别的程序的按键。
        /// 用途：02、03、04 的主要工作都在一个 .NET 调用里，PowerShell 要等它返回才响应 Ctrl+C，所以改用 Esc 提前结束。
        public static bool EscapePressed()
        {
            try
            {
                while (Console.KeyAvailable)
                {
                    if (Console.ReadKey(true).Key == ConsoleKey.Escape) return true;
                }
            }
            catch (Exception) { }   // 输入被重定向、控制台出错等：当作没按
            return false;
        }

        /// SHQueryUserNotificationState 的结果，翻成文字。
        public static string NotificationState()
        {
            int state;
            int result;
            try { result = Native.SHQueryUserNotificationState(out state); }
            catch (Exception) { return "查询失败"; }
            if (result < 0) return "查询失败 0x" + result.ToString("X8");
            switch (state)
            {
                case 1: return "1 不在场（屏保、锁屏或切换了用户）";
                case 2: return "2 忙（有全屏应用，或开了演示设置）";
                case 3: return "3 有独占全屏的 Direct3D 应用";
                case 4: return "4 演示模式";
                case 5: return "5 正常";
                case 6: return "6 免打扰时段";
                case 7: return "7 有沉浸式应用";
                default: return state.ToString();
            }
        }

        /// 鼠标主键（考虑了左右键对调）此刻是否按着。
        public static bool PrimaryButtonDown()
        {
            int key = Native.GetSystemMetrics(23) != 0 ? 0x02 : 0x01;   // 23 = SM_SWAPBUTTON
            return (Native.GetAsyncKeyState(key) & 0x8000) != 0;
        }

        /// 返回 { x, y }。
        public static int[] CursorPosition()
        {
            POINT point;
            Native.GetCursorPos(out point);
            return new int[] { point.X, point.Y };
        }

        /// 返回 { SM_CXDRAG, SM_CYDRAG }。
        public static int[] DragThreshold()
        {
            return new int[] { Native.GetSystemMetrics(68), Native.GetSystemMetrics(69) };
        }

        /// 某个屏幕坐标所在显示器的缩放（DPI）。失败返回 0。
        public static int DpiAt(int x, int y)
        {
            try
            {
                POINT point;
                point.X = x;
                point.Y = y;
                IntPtr monitor = Native.MonitorFromPoint(point, 2);   // MONITOR_DEFAULTTONEAREST
                uint dpiX;
                uint dpiY;
                if (Native.GetDpiForMonitor(monitor, 0, out dpiX, out dpiY) < 0) return 0;
                return (int)dpiX;
            }
            catch (Exception) { return 0; }
        }

        public static string ExStyleText(IntPtr hwnd)
        {
            int style = Native.GetWindowLong(hwnd, -20);   // GWL_EXSTYLE
            List<string> parts = new List<string>();
            if ((style & 0x00080000) != 0) parts.Add("LAYERED");
            if ((style & 0x00000020) != 0) parts.Add("TRANSPARENT");
            if ((style & 0x08000000) != 0) parts.Add("NOACTIVATE");
            if ((style & 0x00000080) != 0) parts.Add("TOOLWINDOW");
            if ((style & 0x00000008) != 0) parts.Add("TOPMOST");
            if ((style & 0x00200000) != 0) parts.Add("NOREDIRECTIONBITMAP");
            return string.Join(" | ", parts.ToArray());
        }
    }

    public static class VirtualDesktop
    {
        /// "是" / "否" / "查询失败…"。
        public static string IsOnCurrent(IntPtr hwnd)
        {
            try
            {
                Type type = Type.GetTypeFromCLSID(new Guid("AA509086-5CA9-4C25-8F95-589D3C07B48A"));
                IVirtualDesktopManager manager = (IVirtualDesktopManager)Activator.CreateInstance(type);
                int onCurrent;
                int result = manager.IsWindowOnCurrentVirtualDesktop(hwnd, out onCurrent);
                if (result < 0) return "查询失败 0x" + result.ToString("X8");
                return onCurrent != 0 ? "是" : "否";
            }
            catch (Exception ex)
            {
                return "查询失败（" + ex.GetType().Name + "）";
            }
        }
    }

    public static class RecycleBin
    {
        /// 最近一次 ItemCount() 是怎么取到的（或为什么没取到）。
        public static string LastNote = "";

        /// 所有驱动器的回收站里一共有几项。失败返回 -1。
        public static long ItemCount()
        {
            int result;
            long items;
            if (IntPtr.Size == 8)
            {
                SHQUERYRBINFO64 info = new SHQUERYRBINFO64();
                info.cbSize = Marshal.SizeOf(typeof(SHQUERYRBINFO64));
                result = Native.SHQueryRecycleBin64(null, ref info);
                LastNote = "传 NULL";
                if (result < 0)
                {
                    int first = result;
                    result = Native.SHQueryRecycleBin64("", ref info);
                    LastNote = "传 NULL 失败（0x" + first.ToString("X8") + "），改传空字符串";
                }
                items = info.i64NumItems;
            }
            else
            {
                SHQUERYRBINFO32 info = new SHQUERYRBINFO32();
                info.cbSize = Marshal.SizeOf(typeof(SHQUERYRBINFO32));
                result = Native.SHQueryRecycleBin32(null, ref info);
                LastNote = "传 NULL";
                if (result < 0)
                {
                    int first = result;
                    result = Native.SHQueryRecycleBin32("", ref info);
                    LastNote = "传 NULL 失败（0x" + first.ToString("X8") + "），改传空字符串";
                }
                items = info.i64NumItems;
            }
            if (result < 0)
            {
                LastNote = LastNote + "也失败（0x" + result.ToString("X8") + "）";
                return -1;
            }
            LastNote = LastNote + "成功";
            return items;
        }
    }

    // ---------------------------------------------------------------- 拖动观察（02-drag-watch.ps1）
    // 两个线程：主线程每隔几毫秒看一次鼠标主键（Sleep(5)，按系统计时器的默认精度实际约 15 毫秒）；后台线程不停地读图标位置。
    // 分开的原因：读取可能被资源管理器卡住，卡住期间主线程照样记得下按下和松开的准确时刻。

    public static class DragWatch
    {
        private sealed class Entry
        {
            public double Time;      // 记下这条的时刻（毫秒）；对读取来说是读取返回的时刻
            public double Started;   // 对读取来说是读取发出的时刻
            public string Kind;      // down / up / stall / moved / count / error / stats
            public string Text;
            public int Dx;
            public int Dy;
        }

        private static readonly object Gate = new object();
        private static readonly List<Entry> Entries = new List<Entry>();
        private static volatile bool stopRequested;

        private static void Add(double time, double started, string kind, string text, int dx, int dy)
        {
            Entry entry = new Entry();
            entry.Time = time;
            entry.Started = started;
            entry.Kind = kind;
            entry.Text = text;
            entry.Dx = dx;
            entry.Dy = dy;
            lock (Gate) { Entries.Add(entry); }
        }

        private static void QueryLoop(Stopwatch clock)
        {
            DesktopView view;
            try { view = DesktopView.Open(); }
            catch (Exception ex)
            {
                Add(clock.Elapsed.TotalMilliseconds, 0, "error", "后台线程打不开桌面视图：" + ex.Message, 0, 0);
                return;
            }
            int[] lastX = null;
            int[] lastY = null;
            int reads = 0;
            double total = 0;
            double longest = 0;
            while (!stopRequested)
            {
                double started = clock.Elapsed.TotalMilliseconds;
                List<IconInfo> icons = null;
                string error = null;
                try { icons = view.ReadIcons(false); }
                catch (Exception ex) { error = ex.Message; }
                double finished = clock.Elapsed.TotalMilliseconds;
                double took = finished - started;
                if (error != null)
                {
                    Add(finished, started, "error", "读取失败（耗时 " + took.ToString("F0") + " 毫秒）：" + error, 0, 0);
                }
                else
                {
                    reads++;
                    total += took;
                    if (took > longest) longest = took;
                    if (took > 100)
                    {
                        Add(finished, started, "stall", "一次读取用了 " + took.ToString("F0") + " 毫秒（发出于 " + started.ToString("F0") + " 毫秒）", 0, 0);
                    }
                    if (lastX != null && lastX.Length == icons.Count)
                    {
                        for (int i = 0; i < icons.Count; i++)
                        {
                            if (icons[i].RawX != lastX[i] || icons[i].RawY != lastY[i])
                            {
                                int dx = icons[i].RawX - lastX[i];
                                int dy = icons[i].RawY - lastY[i];
                                Add(finished, started, "moved",
                                    "图标 #" + i + " 的位置变了：(" + lastX[i] + "," + lastY[i] + ") → (" + icons[i].RawX + "," + icons[i].RawY
                                    + ")，位移 (" + dx + "," + dy + ")；这次读取发出于 " + started.ToString("F0") + " 毫秒", dx, dy);
                            }
                        }
                    }
                    else if (lastX != null)
                    {
                        Add(finished, started, "count", "图标个数变了：" + lastX.Length + " → " + icons.Count, 0, 0);
                    }
                    lastX = new int[icons.Count];
                    lastY = new int[icons.Count];
                    for (int k = 0; k < icons.Count; k++)
                    {
                        lastX[k] = icons[k].RawX;
                        lastY[k] = icons[k].RawY;
                    }
                }
                Thread.Sleep(30);
            }
            string average = reads > 0 ? (total / reads).ToString("F1") : "—";
            Add(clock.Elapsed.TotalMilliseconds, 0, "stats",
                "后台线程共完成 " + reads + " 次读取，平均 " + average + " 毫秒，最长 " + longest.ToString("F0") + " 毫秒", 0, 0);
        }

        /// 观察 seconds 秒，返回按时间排好的记录和小结。
        public static string[] Run(int seconds)
        {
            lock (Gate) { Entries.Clear(); }
            stopRequested = false;
            DesktopView.UsePerMonitorDpi();
            Stopwatch clock = Stopwatch.StartNew();

            Thread worker = new Thread(delegate() { QueryLoop(clock); });
            worker.SetApartmentState(ApartmentState.STA);
            worker.IsBackground = true;
            worker.Start();

            bool wasDown = false;
            POINT downAt = new POINT();
            while (clock.Elapsed.TotalSeconds < seconds && !WindowInfo.EscapePressed())
            {
                bool down = WindowInfo.PrimaryButtonDown();
                if (down != wasDown)
                {
                    POINT point;
                    Native.GetCursorPos(out point);
                    double now = clock.Elapsed.TotalMilliseconds;
                    if (down)
                    {
                        downAt = point;
                        Add(now, now, "down", "鼠标主键按下，位置 (" + point.X + "," + point.Y + ")", 0, 0);
                    }
                    else
                    {
                        int dx = point.X - downAt.X;
                        int dy = point.Y - downAt.Y;
                        Add(now, now, "up", "鼠标主键松开，位置 (" + point.X + "," + point.Y + ")，相对按下点位移 (" + dx + "," + dy + ")", dx, dy);
                    }
                    wasDown = down;
                }
                Thread.Sleep(5);
            }
            stopRequested = true;
            bool joined = worker.Join(20000);

            List<Entry> sorted;
            lock (Gate) { sorted = new List<Entry>(Entries); }
            sorted.Sort(delegate(Entry a, Entry b) { return a.Time.CompareTo(b.Time); });

            List<string> lines = new List<string>();
            foreach (Entry entry in sorted)
            {
                lines.Add("[" + entry.Time.ToString("F0").PadLeft(7) + " 毫秒] " + entry.Text);
            }
            if (!joined) lines.Add("（后台线程 20 秒内没有结束：最后一次读取一直没有返回）");

            lines.Add("");
            lines.Add("—— 小结 ——");
            double downTime = -1;
            int press = 0;
            for (int i = 0; i < sorted.Count; i++)
            {
                Entry entry = sorted[i];
                if (entry.Kind == "down") downTime = entry.Time;
                if (entry.Kind != "up" || downTime < 0) continue;

                press++;
                double longestStall = 0;
                bool movedWhileHeld = false;
                Entry firstMoveAfter = null;
                for (int j = 0; j < sorted.Count; j++)
                {
                    Entry other = sorted[j];
                    if (other.Kind == "stall" && other.Time > downTime && other.Started < entry.Time)
                    {
                        double took = other.Time - other.Started;
                        if (took > longestStall) longestStall = took;
                    }
                    if (other.Kind == "moved")
                    {
                        if (other.Time > downTime && other.Time < entry.Time) movedWhileHeld = true;
                        if (firstMoveAfter == null && other.Time >= entry.Time && other.Time < entry.Time + 5000) firstMoveAfter = other;
                    }
                }
                lines.Add("第 " + press + " 次按下到松开（按住 " + (entry.Time - downTime).ToString("F0") + " 毫秒）：");
                if (longestStall > 500)
                {
                    lines.Add("  按住期间有一次读取被卡了 " + longestStall.ToString("F0") + " 毫秒 —— 资源管理器在这期间没有及时回应");
                }
                else
                {
                    lines.Add("  按住期间读取没有明显卡顿（最长 " + longestStall.ToString("F0") + " 毫秒，不到 100 毫秒的不计）");
                }
                lines.Add("  松手之前就读到了位置变化：" + (movedWhileHeld ? "有（拖动途中报告的位置就在变）" : "没有"));
                if (firstMoveAfter != null)
                {
                    string note = firstMoveAfter.Started < entry.Time ? "（这次读取是松手之前发出的，被卡到松手之后才返回）" : "";
                    lines.Add("  松手后 " + (firstMoveAfter.Time - entry.Time).ToString("F0") + " 毫秒读到新位置" + note);
                    lines.Add("  鼠标位移 (" + entry.Dx + "," + entry.Dy + ")，图标位移 (" + firstMoveAfter.Dx + "," + firstMoveAfter.Dy
                        + ")，相差 (" + (entry.Dx - firstMoveAfter.Dx) + "," + (entry.Dy - firstMoveAfter.Dy) + ")");
                }
                else
                {
                    lines.Add("  松手后 5 秒内没有读到位置变化（这次没有拖图标，或者图标回到了原位）");
                }
                downTime = -1;
            }
            if (press == 0) lines.Add("观察期间没有看到鼠标主键的按下和松开。");
            return lines.ToArray();
        }
    }

    // ---------------------------------------------------------------- 鼠标与命中观察（04-pointer.ps1）

    public static class PointerWatch
    {
        public static void Run(int seconds)
        {
            DesktopView.UsePerMonitorDpi();
            int[] threshold = WindowInfo.DragThreshold();
            Stopwatch clock = Stopwatch.StartNew();
            string lastSurface = null;
            string lastState = null;
            bool wasDown = false;
            bool dragging = false;
            POINT downAt = new POINT();
            while (clock.Elapsed.TotalSeconds < seconds && !WindowInfo.EscapePressed())
            {
                POINT point;
                Native.GetCursorPos(out point);
                bool down = WindowInfo.PrimaryButtonDown();
                string surface = WindowInfo.SurfaceAt(point.X, point.Y);
                string state = WindowInfo.NotificationState();
                string stamp = "[" + clock.Elapsed.TotalSeconds.ToString("F1").PadLeft(5) + " 秒] ";

                if (surface != lastSurface)
                {
                    Console.WriteLine(stamp + "鼠标 (" + point.X + "," + point.Y + ") 处最上面：" + surface);
                    lastSurface = surface;
                }
                if (state != lastState)
                {
                    Console.WriteLine(stamp + "系统状态：" + state);
                    lastState = state;
                }
                if (down && !wasDown)
                {
                    downAt = point;
                    dragging = false;
                    Console.WriteLine(stamp + "主键按下，按下处：" + surface);
                }
                if (down && !dragging)
                {
                    int dx = Math.Abs(point.X - downAt.X);
                    int dy = Math.Abs(point.Y - downAt.Y);
                    if (dx > threshold[0] || dy > threshold[1])
                    {
                        dragging = true;
                        Console.WriteLine(stamp + "越过了系统的起拖阈值（已移动 " + dx + "," + dy + "；阈值 " + threshold[0] + "," + threshold[1] + "）");
                    }
                }
                if (!down && wasDown)
                {
                    Console.WriteLine(stamp + (dragging ? "松手（按阈值算是一次拖拽）" : "松手（没有越过阈值，算点击）")
                        + "，松手处：" + surface + "，相对按下点位移 (" + (point.X - downAt.X) + "," + (point.Y - downAt.Y) + ")");
                    dragging = false;
                }
                wasDown = down;
                Thread.Sleep(20);
            }
        }
    }

    // ---------------------------------------------------------------- 画框的叠加窗口（03-overlay.ps1）
    // 一个盖住整个虚拟屏幕、透明、点击穿透的窗口，在每个图标的位置上画框，用来肉眼核对。
    //   红框 = 候选一：把读到的位置当作"格子的左上角"，图标图像在格子里水平居中，边长用读到的图标边长
    //   青框 = 候选三：同候选一，但边长按图标所在屏的缩放放大（防"读到的边长是 96 DPI 下的逻辑尺寸"）
    //   绿框 = 候选二：把读到的位置当作"图标图像的左上角"
    //   橙框 = 文字矩形的估算：从红框下沿到格子下沿，宽度等于格子宽
    //   蓝框 = 整个格子（位置 + GetSpacing）
    // 带 -NoRedirectionBitmap 时：不用分层样式，改带"不分配后台画布"的样式，什么都不画，只测这种窗口点不点得穿。

    public sealed class OverlayForm : Form
    {
        private readonly string mode;           // bottom / follow / owner / topmost
        private readonly bool noRedirection;
        private readonly int seconds;
        private DesktopView desktop;            // 资源管理器重启后会重连，所以不是只读的
        private string lastReadError;
        private double nextReconnect;
        private bool inTimer;
        private readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        private readonly Stopwatch clock = Stopwatch.StartNew();
        private List<IconInfo> icons = new List<IconInfo>();
        private int iconSize = 48;
        private int cellWidth = 76;
        private int cellHeight = 100;
        private double nextReport;
        private bool raised;
        private string lastSignature = "";

        public OverlayForm(string mode, int seconds, bool noRedirection)
        {
            this.mode = mode;
            this.seconds = seconds;
            this.noRedirection = noRedirection;
            DesktopView.UsePerMonitorDpi();
            desktop = DesktopView.Open();

            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            Bounds = SystemInformation.VirtualScreen;
            if (!noRedirection)
            {
                // 颜色键透明：这一种颜色的像素完全透明。分层窗口最简单的用法，不支持半透明，只用来核对位置
                BackColor = Color.Fuchsia;
                TransparencyKey = Color.Fuchsia;
                DoubleBuffered = true;
            }
            timer.Interval = 400;
            timer.Tick += OnTimer;
        }

        protected override CreateParams CreateParams
        {
            get
            {
                // 注意：基类的构造过程中这里也可能被调用，那时 mode 还是 null、noRedirection 还是 false，下面的判断都不会出错
                CreateParams parameters = base.CreateParams;
                // TRANSPARENT | NOACTIVATE | TOOLWINDOW：从创建那一刻起就不抢焦点
                parameters.ExStyle |= 0x00000020 | 0x08000000 | 0x00000080;
                // 平时再加 LAYERED（和 TRANSPARENT 一起才点得穿）；-NoRedirectionBitmap 时换成 NOREDIRECTIONBITMAP、不加 LAYERED
                parameters.ExStyle |= noRedirection ? 0x00200000 : 0x00080000;
                if (mode == "topmost") parameters.ExStyle |= 0x00000008;
                return parameters;
            }
        }

        protected override bool ShowWithoutActivation
        {
            get { return true; }
        }

        protected override void CreateHandle()
        {
            // ShowInTaskbar 为 false 时，WinForms 会在这一步里把属主设成它自己的一个隐藏窗口，所以属主要在这之后再改
            base.CreateHandle();
            ApplyOwner();
        }

        private void ApplyOwner()
        {
            if (mode != "owner" || desktop == null || desktop.RootWindow == IntPtr.Zero) return;
            // GWLP_HWNDPARENT（-8）：对顶层窗口来说就是属主
            if (IntPtr.Size == 8) Native.SetWindowLongPtr64(Handle, -8, desktop.RootWindow);
            else Native.SetWindowLong32(Handle, -8, desktop.RootWindow.ToInt32());
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            ApplyOwner();   // 万一显示的过程中又被改回去
            if (mode == "owner")
            {
                // 改属主不会挪动 Z 序，新窗口本来排在最前面。手动把它放到紧挨着属主（桌面窗口）的上方，和沉底模式可比
                IntPtr above = desktop.RootWindow != IntPtr.Zero ? Native.GetWindow(desktop.RootWindow, 3) : IntPtr.Zero;   // 3 = GW_HWNDPREV
                if (above != IntPtr.Zero && above != Handle)
                {
                    Native.SetWindowPos(Handle, above, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
                }
            }
            else
            {
                // 1 = HWND_BOTTOM，-1 = HWND_TOPMOST；0x13 = NOSIZE | NOMOVE | NOACTIVATE
                IntPtr after = mode == "topmost" ? new IntPtr(-1) : new IntPtr(1);
                Native.SetWindowPos(Handle, after, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
            }
            try { RefreshIcons(); }
            catch (Exception ex) { Console.WriteLine("读图标失败：" + ex.Message); }
            Rectangle virtualScreen = SystemInformation.VirtualScreen;
            string range = "(" + Bounds.X + "," + Bounds.Y + " " + Bounds.Width + "×" + Bounds.Height + ")";
            string rangeNote = Bounds == virtualScreen
                ? "，与虚拟屏幕一致"
                : "，与虚拟屏幕 (" + virtualScreen.X + "," + virtualScreen.Y + " " + virtualScreen.Width + "×" + virtualScreen.Height + ") 不一致——窗口被系统截小了";
            Console.WriteLine("叠加窗口已显示。模式 " + mode + (noRedirection ? "（不分层、不分配后台画布、不画任何东西）" : "")
                + "；窗口样式 " + WindowInfo.ExStyleText(Handle)
                + "；实际属主 " + WindowInfo.ClassOf(Native.GetWindow(Handle, 4))   // 4 = GW_OWNER
                + "；范围 " + range + rangeNote
                + "；图标 " + icons.Count + " 个，读到的图标边长 " + iconSize + "，格子 " + cellWidth + "×" + cellHeight);
            Console.WriteLine("想提前结束：直接按 Esc；如果之前点过别处，先用 Alt+Tab 切回这个 PowerShell 窗口再按。");
            timer.Start();
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            timer.Stop();
            base.OnFormClosed(e);
            Console.WriteLine("叠加窗口已关闭。");
        }

        private void RefreshIcons()
        {
            List<IconInfo> latest = desktop.ReadIcons(false);
            int[] spacing = desktop.Spacing();
            if (spacing[0] >= 0 && spacing[1] > 0 && spacing[2] > 0)
            {
                cellWidth = spacing[1];
                cellHeight = spacing[2];
            }
            int[] size = desktop.ViewModeAndIconSize();
            if (size[0] >= 0 && size[2] > 0) iconSize = size[2];
            icons = latest;

            // 没有任何变化就不重画
            StringBuilder signature = new StringBuilder();
            foreach (IconInfo icon in latest)
            {
                signature.Append(icon.PositionResult).Append(':').Append(icon.ScreenX).Append(',').Append(icon.ScreenY)
                    .Append('@').Append(WindowInfo.DpiAt(icon.ScreenX, icon.ScreenY)).Append(';');
            }
            signature.Append(cellWidth).Append('x').Append(cellHeight).Append('/').Append(iconSize);
            string text = signature.ToString();
            if (text != lastSignature)
            {
                lastSignature = text;
                Invalidate();
            }
        }

        private Rectangle ImageRectA(IconInfo icon)
        {
            return new Rectangle(icon.ScreenX + (cellWidth - iconSize) / 2, icon.ScreenY, iconSize, iconSize);
        }

        private Rectangle ImageRectB(IconInfo icon)
        {
            return new Rectangle(icon.ScreenX, icon.ScreenY, iconSize, iconSize);
        }

        private Rectangle ImageRectScaled(IconInfo icon)
        {
            int dpi = WindowInfo.DpiAt(icon.ScreenX, icon.ScreenY);
            int side = dpi > 0 ? iconSize * dpi / 96 : iconSize;
            return new Rectangle(icon.ScreenX + (cellWidth - side) / 2, icon.ScreenY, side, side);
        }

        private Rectangle LabelRectEstimate(IconInfo icon)
        {
            Rectangle image = ImageRectA(icon);
            int top = image.Bottom + 2;
            int bottom = icon.ScreenY + cellHeight;
            return new Rectangle(icon.ScreenX, top, cellWidth, Math.Max(0, bottom - top));
        }

        private Rectangle CellRect(IconInfo icon)
        {
            return new Rectangle(icon.ScreenX, icon.ScreenY, cellWidth, cellHeight);
        }

        private Rectangle ToClient(Rectangle onScreen)
        {
            Point origin = PointToClient(new Point(onScreen.X, onScreen.Y));
            return new Rectangle(origin.X, origin.Y, onScreen.Width, onScreen.Height);
        }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            if (noRedirection) return;   // 这种窗口没有可画的表面
            base.OnPaintBackground(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            if (noRedirection) return;
            Graphics g = e.Graphics;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.SingleBitPerPixelGridFit;
            using (Pen red = new Pen(Color.Red, 2))
            using (Pen cyan = new Pen(Color.Cyan, 1))
            using (Pen green = new Pen(Color.Lime, 2))
            using (Pen orange = new Pen(Color.Orange, 1))
            using (Pen blue = new Pen(Color.DodgerBlue, 1))
            using (Font font = new Font("Segoe UI", 9f))
            using (Brush textBrush = new SolidBrush(Color.Yellow))
            {
                foreach (IconInfo icon in icons)
                {
                    if (icon.PositionResult != 0) continue;   // 位置没读到的不画
                    Rectangle cell = ToClient(CellRect(icon));
                    g.DrawRectangle(blue, cell);
                    g.DrawRectangle(orange, ToClient(LabelRectEstimate(icon)));
                    g.DrawRectangle(red, ToClient(ImageRectA(icon)));
                    g.DrawRectangle(cyan, ToClient(ImageRectScaled(icon)));
                    g.DrawRectangle(green, ToClient(ImageRectB(icon)));
                    g.DrawString(icon.Index.ToString(), font, textBrush, cell.X + 2, cell.Bottom - 16);
                }
            }
        }

        private void OnTimer(object sender, EventArgs e)
        {
            // 等资源管理器回应的时候系统可能处理消息，计时器会重入；重入的那一次直接跳过
            if (inTimer) return;
            inTimer = true;
            try
            {
                double now = clock.Elapsed.TotalSeconds;
                if (now >= seconds || WindowInfo.EscapePressed())
                {
                    timer.Stop();
                    Close();
                    return;
                }
                ReadOrReconnect(now);
                if (mode == "follow") Follow();
                if (now >= nextReport)
                {
                    nextReport = now + 2.0;
                    Report(now);
                }
            }
            finally
            {
                inTimer = false;
            }
        }

        // 读不到时（典型情形是资源管理器重启了）：同样的错误只打印一次，每 2 秒重连一次桌面视图。
        // 重连后故意不重设属主——属主模式下要看的就是"资源管理器重启之后属主丢没丢"。
        private void ReadOrReconnect(double now)
        {
            try
            {
                RefreshIcons();
                if (lastReadError != null)
                {
                    Console.WriteLine("[" + now.ToString("F0").PadLeft(3) + " 秒] 又能读到图标了");
                    lastReadError = null;
                }
            }
            catch (Exception ex)
            {
                if (ex.Message != lastReadError)
                {
                    Console.WriteLine("[" + now.ToString("F0").PadLeft(3) + " 秒] 读图标失败：" + ex.Message + "（同样的错误不再重复打印；每 2 秒重连一次）");
                    lastReadError = ex.Message;
                }
                if (now >= nextReconnect)
                {
                    nextReconnect = now + 2.0;
                    try
                    {
                        desktop = DesktopView.Open();
                        Console.WriteLine("[" + now.ToString("F0").PadLeft(3) + " 秒] 重新连上了桌面视图");
                    }
                    catch (Exception) { }
                }
            }
        }

        // "沉底 + 显示桌面时上浮"的最简版本：桌面成了前台、而且排到了我们上面，就把自己提到最上（不激活）；
        // 前台换成别的窗口后再沉回最底。
        private void Follow()
        {
            IntPtr foreground = Native.GetForegroundWindow();
            bool desktopInFront = foreground != IntPtr.Zero
                && (foreground == desktop.RootWindow || WindowInfo.IsDesktopRoot(foreground));
            int mine = WindowInfo.ZIndexOf(Handle);
            int desk = WindowInfo.ZIndexOf(desktop.RootWindow);
            bool covered = mine >= 0 && desk >= 0 && desk < mine;
            if (desktopInFront && covered)
            {
                Native.SetWindowPos(Handle, IntPtr.Zero, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);   // HWND_TOP
                raised = true;
                Console.WriteLine("[follow] 桌面被提到了叠加窗口上面（显示桌面），已把叠加窗口提到最上");
            }
            else if (raised && !desktopInFront)
            {
                Native.SetWindowPos(Handle, new IntPtr(1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);  // HWND_BOTTOM
                raised = false;
                Console.WriteLine("[follow] 前台换成了别的窗口，已把叠加窗口沉回最底");
            }
        }

        private void Report(double now)
        {
            int mine = WindowInfo.ZIndexOf(Handle);
            int desk = WindowInfo.ZIndexOf(desktop.RootWindow);
            string relation;
            if (mine < 0 || desk < 0) relation = "与桌面窗口的上下关系查不出";
            else if (mine < desk) relation = "在桌面窗口之上";
            else relation = "在桌面窗口之下（被桌面盖住了）";

            string line = "[" + now.ToString("F0").PadLeft(3) + " 秒] 叠加窗口" + relation
                + "；它上面有 " + WindowInfo.VisibleWindowsAbove(Handle) + " 个可见的顶层窗口"
                + "；前台是" + WindowInfo.Category(Native.GetForegroundWindow())
                + "；在当前虚拟桌面：" + VirtualDesktop.IsOnCurrent(Handle)
                + "；属主 " + WindowInfo.ClassOf(Native.GetWindow(Handle, 4));   // 4 = GW_OWNER
            foreach (IconInfo icon in icons)
            {
                if (icon.PositionResult != 0) continue;
                Rectangle first = ImageRectA(icon);
                line += "；图标 #" + icon.Index + " 中心处最上面：" + WindowInfo.SurfaceAt(first.X + first.Width / 2, first.Y + first.Height / 2);
                break;
            }
            Console.WriteLine(line);
        }

        public static void RunFor(string mode, int seconds, bool noRedirection)
        {
            using (OverlayForm form = new OverlayForm(mode, seconds, noRedirection))
            {
                Application.Run(form);
            }
        }
    }
}
'@

    $compileErrors = $null
    try {
        Add-Type -TypeDefinition $ddmProbeSource -Language CSharp -IgnoreWarnings `
            -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing') `
            -ErrorAction SilentlyContinue -ErrorVariable compileErrors
    } catch { }
    if (-not ('DdmProbe.DesktopView' -as [type])) {
        # 不打印系统给的报错原文：里面带着编译用临时文件的完整路径（含 Windows 用户名）
        Write-Host '内嵌的 C# 编译失败。请把下面几行交给负责 Windows 版的人（只有行号和错误说明，不含路径）：'
        foreach ($record in @($compileErrors)) {
            $compilerError = $record.TargetObject
            if ($compilerError -is [System.CodeDom.Compiler.CompilerError]) {
                Write-Host ('  common.ps1 第 {0} 行第 {1} 列 {2}：{3}' -f ($compilerError.Line + $ddmSourceLineOffset), $compilerError.Column, $compilerError.ErrorNumber, $compilerError.ErrorText)
            }
        }
        exit 1
    }
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('== ' + $Title + ' ==')
}

# 把视图标志位翻成文字（只列和本项目有关的几个）。
function Format-FolderFlags {
    param([long]$Flags)
    $names = @()
    if ($Flags -band 0x1)     { $names += 'FWF_AUTOARRANGE(自动排列)' }
    if ($Flags -band 0x4)     { $names += 'FWF_SNAPTOGRID(对齐网格)' }
    if ($Flags -band 0x20)    { $names += 'FWF_DESKTOP' }
    if ($Flags -band 0x1000)  { $names += 'FWF_NOICONS(不显示图标)' }
    if ($Flags -band 0x20000) { $names += 'FWF_HIDEFILENAMES' }
    return ('0x{0:X8}  {1}' -f $Flags, ($names -join ' | '))
}

# 当前用户的"不显示桌面图标"注册表值（候选信号之一）。读不到返回 '(没有这个值)'。
function Get-HideIconsRegistryValue {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    try {
        $value = (Get-ItemProperty -Path $key -Name 'HideIcons' -ErrorAction Stop).HideIcons
        return [string]$value
    } catch {
        return '(没有这个值)'
    }
}
