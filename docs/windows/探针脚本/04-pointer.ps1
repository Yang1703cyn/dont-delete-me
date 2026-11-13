# ============================================================================
# 未经运行。
# 这个文件是在一台 Mac 上写的，没有在任何 Windows 电脑上运行过，只做过人工通读和一次独立审阅。
# ============================================================================
#
# 探针 04：鼠标、命中判断、起拖阈值、系统状态（验证清单 V05、V13、V20、V22）
#
# 做什么：每 20 毫秒读一次鼠标位置和主键状态（只是查询，不拦截、不修改任何输入），问系统"这个点上是哪个窗口"，
#         有变化时打印一行。只打印窗口的类名和它属于谁（本进程 / 资源管理器 / 另一个 PowerShell / 别的程序），
#         不打印窗口标题，也不打印别的程序的名字。
#
# 用法：
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\04-pointer.ps1
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\04-pointer.ps1 -Seconds 60
# 想提前结束：直接按 Esc；如果之前点过别处，先用 Alt+Tab 切回这个 PowerShell 窗口再按（观察期间 Ctrl+C 不起作用）。
#
# 运行期间请依次把鼠标移到：桌面空白处 → 一个桌面图标上 → 任意普通窗口上 → 任务栏上；
# 然后在一个自己的测试图标上：单击一下；按住不动 2 秒再松开；按住慢慢拖出去再松手。
# 再把一个窗口最大化（或开一个全屏视频），看"系统状态"那一行变不变。
# 想同时验证"命中判断会不会被我们自己的穿透窗口挡住"，另开一个 PowerShell 窗口先运行 03-overlay.ps1，再运行本脚本：
# 鼠标在图标上时应当仍是"桌面图标层"，而不是"另一个 PowerShell 进程的窗口"。

param(
    [int]$Seconds = 40
)

# 出错时只打印文件名、行号和错误说明，不打印含用户名的完整路径
trap { Write-Host ('出错（{0} 第 {1} 行）：{2}' -f [IO.Path]::GetFileName([string]$_.InvocationInfo.ScriptName), $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message); exit 1 }

. "$PSScriptRoot\common.ps1"

Write-Section '桌面窗口的层级（只有类名）'
$view = [DdmProbe.DesktopView]::Open()
Write-Host ('列表窗口 {0}  ←  视图窗口 {1}  ←  顶层窗口 {2}' -f `
    [DdmProbe.WindowInfo]::ClassOf($view.ListWindow), [DdmProbe.WindowInfo]::ClassOf($view.ViewWindow), [DdmProbe.WindowInfo]::ClassOf($view.RootWindow))
Write-Host ('IShellBrowser 报告的窗口：{0}' -f [DdmProbe.WindowInfo]::ClassOf($view.BrowserWindow))
Write-Host ('系统给出的桌面窗口（GetShellWindow）：{0}；它直接含有 SHELLDLL_DefView 子窗口：{1}' -f `
    [DdmProbe.WindowInfo]::ShellWindowClass(), [DdmProbe.WindowInfo]::ShellWindowHasDefView())
$build = ''
try {
    # 只取这三个值（这个注册表项里还有登记的用户名等，不读）
    $key = Get-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $build = '（版本 {0}，内部版本 {1}.{2}）' -f $key.GetValue('DisplayVersion', $key.GetValue('ReleaseId', '')), $key.GetValue('CurrentBuild'), $key.GetValue('UBR')
} catch { }
Write-Host ('系统版本：{0}{1}' -f [System.Environment]::OSVersion.VersionString, $build)

Write-Section '系统参数'
$threshold = [DdmProbe.WindowInfo]::DragThreshold()
Write-Host ('起拖阈值 SM_CXDRAG / SM_CYDRAG：{0} / {1} 像素' -f $threshold[0], $threshold[1])
$position = [DdmProbe.WindowInfo]::CursorPosition()
Write-Host ('鼠标所在显示器的缩放：{0} DPI（96 = 100%）' -f [DdmProbe.WindowInfo]::DpiAt($position[0], $position[1]))

Write-Section ('开始观察 {0} 秒：有变化才打印' -f $Seconds)
[DdmProbe.PointerWatch]::Run($Seconds)
Write-Host '观察结束。'
