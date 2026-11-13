# ============================================================================
# 未经运行。
# 这个文件是在一台 Mac 上写的，没有在任何 Windows 电脑上运行过，只做过人工通读和一次独立审阅。
# ============================================================================
#
# 探针 07：显示器与缩放（验证清单 V10）
#
# 做什么：打印每块显示器在虚拟屏幕里的矩形、是不是主屏、缩放比例，以及整个虚拟屏幕的范围。全程只读。
#         配合 01、03 两个探针，在"两块缩放比例不同的显示器"上核对图标位置的单位。
#
# 用法：
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\07-displays.ps1

# 出错时只打印文件名、行号和错误说明，不打印含用户名的完整路径
trap { Write-Host ('出错（{0} 第 {1} 行）：{2}' -f [IO.Path]::GetFileName([string]$_.InvocationInfo.ScriptName), $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message); exit 1 }

. "$PSScriptRoot\common.ps1"

Add-Type -AssemblyName System.Windows.Forms
[DdmProbe.DesktopView]::UsePerMonitorDpi()

Write-Section '显示器（当前线程按"每显示器 V2"看到的数值，单位是物理像素）'
$index = 0
foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
    $bounds = $screen.Bounds
    $centerX = $bounds.X + [int]($bounds.Width / 2)
    $centerY = $bounds.Y + [int]($bounds.Height / 2)
    $dpi = [DdmProbe.WindowInfo]::DpiAt($centerX, $centerY)
    $scale = '读不到'
    if ($dpi -gt 0) { $scale = '{0:F0}%' -f (100.0 * $dpi / 96) }
    Write-Host ('显示器 {0}：矩形 ({1},{2} {3}×{4})；主屏：{5}；缩放 {6}（{7} DPI）' -f $index, $bounds.X, $bounds.Y, $bounds.Width, $bounds.Height, $screen.Primary, $scale, $dpi)
    $index++
}

$virtual = [System.Windows.Forms.SystemInformation]::VirtualScreen
Write-Host ('虚拟屏幕：({0},{1} {2}×{3})' -f $virtual.X, $virtual.Y, $virtual.Width, $virtual.Height)

Write-Section '桌面图标落在哪块屏上'
try {
    $view = [DdmProbe.DesktopView]::Open()
    $icons = $view.ReadIcons($false)
    $index = 0
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $bounds = $screen.Bounds
        $inside = @($icons | Where-Object { $_.ScreenX -ge $bounds.Left -and $_.ScreenX -lt $bounds.Right -and $_.ScreenY -ge $bounds.Top -and $_.ScreenY -lt $bounds.Bottom })
        Write-Host ('显示器 {0}：{1} 个图标的位置落在它的矩形里' -f $index, $inside.Count)
        $index++
    }
    $spacing = $view.Spacing()
    $size = $view.ViewModeAndIconSize()
    Write-Host ('格子 {0}×{1}，图标边长 {2}（混合缩放时，这两个数是按哪块屏的缩放给的，要对照 03 号探针画出的框来判断）' -f $spacing[1], $spacing[2], $size[2])
} catch {
    Write-Host ('读图标失败：' + $_.Exception.Message)
}
