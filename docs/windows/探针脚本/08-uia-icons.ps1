# ============================================================================
# 未经运行。
# 这个文件是在一台 Mac 上写的，没有在任何 Windows 电脑上运行过，只做过人工通读和一次独立审阅。
# ============================================================================
#
# 探针 08：备选路线——用界面自动化（UI Automation）读图标的屏幕矩形（验证清单 V15）
#
# 做什么：经系统自带的界面自动化接口，列出桌面列表控件的每个子项的屏幕矩形，量一下耗时；
#         再给每一项找文件夹视图接口（探针 01 那条路线）读到的、离它最近的那个图标，逐个对比，
#         看两者之间是不是差一个固定的偏移（这个偏移能帮我们确定图像矩形该怎么推算）。
#         全程只读。不打印任何名字。
#
# 用法：
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\08-uia-icons.ps1
# 运行中按 Ctrl+C 可以中止。

# 出错时只打印文件名、行号和错误说明，不打印含用户名的完整路径
trap { Write-Host ('出错（{0} 第 {1} 行）：{2}' -f [IO.Path]::GetFileName([string]$_.InvocationInfo.ScriptName), $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message); exit 1 }

. "$PSScriptRoot\common.ps1"

Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName UIAutomationClient

[DdmProbe.DesktopView]::UsePerMonitorDpi()
$view = [DdmProbe.DesktopView]::Open()
if ($view.ListWindow -eq [IntPtr]::Zero) {
    Write-Host '没有找到桌面的列表窗口，无法继续。'
    return
}

Write-Section '经界面自动化枚举'
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$root = [System.Windows.Automation.AutomationElement]::FromHandle($view.ListWindow)
$children = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
$rows = @()
foreach ($child in $children) {
    $rect = $child.Current.BoundingRectangle
    $x = 0; $y = 0; $width = 0; $height = 0
    if (-not $rect.IsEmpty) {
        # 空矩形的坐标是无穷大，不能直接转成整数
        $x = [int]$rect.X; $y = [int]$rect.Y; $width = [int]$rect.Width; $height = [int]$rect.Height
    }
    $rows += [pscustomobject]@{
        Type      = $child.Current.ControlType.ProgrammaticName
        X         = $x
        Y         = $y
        Width     = $width
        Height    = $height
        Offscreen = $child.Current.IsOffscreen
    }
}
$stopwatch.Stop()
Write-Host ('子项 {0} 个，枚举并读出矩形共用 {1:F0} 毫秒' -f $rows.Count, $stopwatch.Elapsed.TotalMilliseconds)
$types = $rows | Group-Object Type
foreach ($type in $types) { Write-Host ('  控件类型 {0}：{1} 个' -f $type.Name, $type.Count) }

Write-Section '和文件夹视图接口的读数对比'
$icons = $view.ReadIcons($false)
$spacing = $view.Spacing()
$size = $view.ViewModeAndIconSize()
Write-Host ('文件夹视图接口：图标 {0} 个，格子 {1}×{2}，图标边长 {3}' -f $icons.Count, $spacing[1], $spacing[2], $size[2])

$items = @($rows | Where-Object { $_.Type -like '*ListItem*' -and $_.Width -gt 0 })
$positions = @($icons | Where-Object { $_.PositionResult -eq 0 })
if ($items.Count -ne $positions.Count) {
    Write-Host ('两边个数不一样（界面自动化的列表项 {0} 个，文件夹视图 {1} 个）。' -f $items.Count, $positions.Count)
}
# 配对：界面自动化的矩形包含文字，宽度随名字长短变，所以不按坐标排序配对，
# 而是给每一项找"格子中心离它的水平中心最近、上沿离它的上沿最近"的那个图标
$cellWidth = $spacing[1]
$used = @{}
Write-Host ('{0,3}  {1,-16}  {2,-22}  {3}' -f '序', '视图接口的位置', '界面自动化的矩形', '矩形左上角 − 位置')
for ($i = 0; $i -lt $items.Count; $i++) {
    $item = $items[$i]
    $centerX = $item.X + $item.Width / 2
    $icon = $positions | Sort-Object { [Math]::Abs($_.ScreenX + $cellWidth / 2 - $centerX) + [Math]::Abs($_.ScreenY - $item.Y) } | Select-Object -First 1
    if ($null -eq $icon) { break }
    $note = ''
    if ($item.Offscreen) { $note += '  [报告为"在屏幕外"]' }
    if ($used.ContainsKey($icon.Index)) { $note += ('  [和第 {0} 行配到了同一个图标]' -f $used[$icon.Index]) } else { $used[$icon.Index] = $i }
    Write-Host ('{0,3}  {1,-16}  {2,-22}  ({3},{4}){5}' -f $i, ('({0},{1})' -f $icon.ScreenX, $icon.ScreenY), `
        ('({0},{1} {2}×{3})' -f $item.X, $item.Y, $item.Width, $item.Height), ($item.X - $icon.ScreenX), ($item.Y - $icon.ScreenY), $note)
}
Write-Host ''
Write-Host '怎么读：最后一列如果每一行都相同（或者 x 随名字长短变、y 不变），说明"整项矩形"和"视图接口给的位置"之间差一个固定的量；'
Write-Host '        界面自动化的矩形宽高如果等于格子大小，它就是整个格子（图像 + 文字）。'
Write-Host '        这个脚本的坐标按物理像素读；缩放不是 100% 时如果和 01 的读数整体差一个比例，说明界面自动化给的不是物理像素。'
