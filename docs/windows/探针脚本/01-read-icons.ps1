# ============================================================================
# 未经运行。
# 这个文件是在一台 Mac 上写的，没有在任何 Windows 电脑上运行过，只做过人工通读和一次独立审阅。
# ============================================================================
#
# 探针 01：读桌面图标（验证清单 V01、V07、V11、V12、V19）
#
# 做什么：经资源管理器的桌面视图接口，读出图标个数、每个图标的位置和种类、格子大小、图标大小、视图标志，
#         并核对认不认得出回收站。全程只读，不移动图标、不改任何设置。
# 不输出图标的名字：每个图标只打印序号、种类、位置。
#
# 用法（在本文件所在的文件夹里）：
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\01-read-icons.ps1
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\01-read-icons.ps1 -Watch -Seconds 90
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\01-read-icons.ps1 -Bench
#
#   不带参数：读一遍，打印全貌（几秒钟）。
#   -Watch  ：持续观察 -Seconds 秒，任何读数一变就打印一行。期间可以去：增删桌面上自己的测试文件、挪图标、
#             改图标大小（Ctrl + 滚轮）、切换"自动排列 / 对齐网格 / 显示桌面图标"、在任务管理器里重启资源管理器。
#   -Bench  ：量读取耗时和资源管理器的处理器占用（约 30 秒）。
#
# 运行中按 Ctrl+C 可以中止（这个脚本的每一步都很短，PowerShell 来得及响应）。

param(
    [switch]$Watch,
    [switch]$Bench,
    [int]$Seconds = 60
)

# 出错时只打印文件名、行号和错误说明，不打印含用户名的完整路径
trap { Write-Host ('出错（{0} 第 {1} 行）：{2}' -f [IO.Path]::GetFileName([string]$_.InvocationInfo.ScriptName), $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message); exit 1 }

. "$PSScriptRoot\common.ps1"

function Get-ViewSummary {
    param($View)
    $spacing = $View.Spacing()
    $size = $View.ViewModeAndIconSize()
    $flags = $View.FolderFlags()
    $auto = $View.AutoArrange()
    $autoText = '读取失败'
    if ($auto -eq 0) { $autoText = '开' } elseif ($auto -eq 1) { $autoText = '关' }
    return [pscustomobject]@{
        Count        = $View.ItemCount()
        CellWidth    = $spacing[1]
        CellHeight   = $spacing[2]
        ViewMode     = $size[1]
        IconSize     = $size[2]
        FlagsOk      = ($flags[0] -ge 0)
        Flags        = $flags[1]
        AutoArrange  = $autoText
        ListVisible  = $View.ListWindowVisible()
        HideIconsReg = Get-HideIconsRegistryValue
    }
}

# 当前登录会话里的资源管理器累计用掉的处理器时间（秒）。别的用户的资源管理器读不到，也不该算进来。
function Get-ExplorerCpuSeconds {
    $session = (Get-Process -Id $PID).SessionId
    $total = 0.0
    foreach ($process in @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })) {
        try { $total += $process.TotalProcessorTime.TotalSeconds } catch { }
    }
    return $total
}

function Get-PositionKey {
    param($Icons)
    $parts = foreach ($icon in $Icons) { '{0},{1}' -f $icon.RawX, $icon.RawY }
    return ($parts -join ';')
}

# ---------------------------------------------------------------------------

Write-Section '桌面视图'
$view = [DdmProbe.DesktopView]::Open()
Write-Host ('浏览器窗口（IShellBrowser）类名：{0}' -f [DdmProbe.WindowInfo]::ClassOf($view.BrowserWindow))
Write-Host ('视图窗口（IShellView）类名    ：{0}' -f [DdmProbe.WindowInfo]::ClassOf($view.ViewWindow))
Write-Host ('列表窗口类名                  ：{0}，可见：{1}' -f [DdmProbe.WindowInfo]::ClassOf($view.ListWindow), $view.ListWindowVisible())
Write-Host ('视图所在的顶层窗口类名        ：{0}，归属：{1}' -f [DdmProbe.WindowInfo]::ClassOf($view.RootWindow), [DdmProbe.WindowInfo]::OwnerOf($view.RootWindow))
Write-Host ('支持 IFolderView2             ：{0}' -f $view.HasFolderView2)

if ($Bench) {
    Write-Section '读取耗时（各 30 次）'
    $stopwatch = New-Object System.Diagnostics.Stopwatch
    $countTimes = @(); $positionTimes = @(); $detailTimes = @()
    $iconCount = 0
    for ($i = 0; $i -lt 30; $i++) {
        $stopwatch.Restart(); $iconCount = $view.ItemCount(); $stopwatch.Stop()
        $countTimes += $stopwatch.Elapsed.TotalMilliseconds
        $stopwatch.Restart(); $null = $view.ReadIcons($false); $stopwatch.Stop()
        $positionTimes += $stopwatch.Elapsed.TotalMilliseconds
        $stopwatch.Restart(); $null = $view.ReadIcons($true); $stopwatch.Stop()
        $detailTimes += $stopwatch.Elapsed.TotalMilliseconds
        Start-Sleep -Milliseconds 100
    }
    foreach ($row in @(@('只数个数', $countTimes), @('读全部位置', $positionTimes), @('位置 + 种类', $detailTimes))) {
        $sorted = $row[1] | Sort-Object
        Write-Host ('{0,-10} 中位 {1,7:F2} 毫秒   最长 {2,7:F2} 毫秒' -f $row[0], $sorted[15], $sorted[29])
    }
    Write-Host ('图标个数：{0}' -f $iconCount)

    Write-Section '资源管理器的处理器占用'
    foreach ($case in @(@('基线（不读取）', 0), @('每秒 1 次读全部位置', 1000), @('每秒 5 次读全部位置', 200))) {
        $before = Get-ExplorerCpuSeconds
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        while ($clock.Elapsed.TotalSeconds -lt 6) {
            if ($case[1] -gt 0) { $null = $view.ReadIcons($false); Start-Sleep -Milliseconds $case[1] }
            else { Start-Sleep -Milliseconds 200 }
        }
        $cpuSeconds = (Get-ExplorerCpuSeconds) - $before
        Write-Host ('{0,-18} 资源管理器用了 {1:F3} 秒处理器 / {2:F1} 秒，占一个核心的 {3:F1}%' -f $case[0], $cpuSeconds, $clock.Elapsed.TotalSeconds, (100 * $cpuSeconds / $clock.Elapsed.TotalSeconds))
    }
    return
}

if ($Watch) {
    Write-Section ('持续观察 {0} 秒：读数一变就打印' -f $Seconds)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $last = $null
    $lastKey = $null
    $connected = $true
    while ($clock.Elapsed.TotalSeconds -lt $Seconds) {
        $stamp = '[{0,5:F1} 秒] ' -f $clock.Elapsed.TotalSeconds
        try {
            if (-not $connected) {
                $view = [DdmProbe.DesktopView]::Open()
                $connected = $true
                Write-Host ($stamp + '重新连上了桌面视图')
            }
            $now = Get-ViewSummary $view
            $icons = $view.ReadIcons($false)
            $key = Get-PositionKey $icons
            if ($null -eq $last) {
                Write-Host ($stamp + ('起始：图标 {0} 个，格子 {1}×{2}，图标边长 {3}，标志 {4}，自动排列 {5}，列表窗口可见 {6}，注册表 HideIcons = {7}' -f `
                    $now.Count, $now.CellWidth, $now.CellHeight, $now.IconSize, (Format-FolderFlags $now.Flags), $now.AutoArrange, $now.ListVisible, $now.HideIconsReg))
            } else {
                if ($now.Count -ne $last.Count) { Write-Host ($stamp + ('图标个数 {0} → {1}' -f $last.Count, $now.Count)) }
                if ($now.CellWidth -ne $last.CellWidth -or $now.CellHeight -ne $last.CellHeight) { Write-Host ($stamp + ('格子 {0}×{1} → {2}×{3}' -f $last.CellWidth, $last.CellHeight, $now.CellWidth, $now.CellHeight)) }
                if ($now.IconSize -ne $last.IconSize -or $now.ViewMode -ne $last.ViewMode) { Write-Host ($stamp + ('图标边长 {0} → {1}（视图模式 {2} → {3}）' -f $last.IconSize, $now.IconSize, $last.ViewMode, $now.ViewMode)) }
                if ($now.Flags -ne $last.Flags) { Write-Host ($stamp + ('视图标志 {0}  →  {1}' -f (Format-FolderFlags $last.Flags), (Format-FolderFlags $now.Flags))) }
                if ($now.AutoArrange -ne $last.AutoArrange) { Write-Host ($stamp + ('自动排列 {0} → {1}' -f $last.AutoArrange, $now.AutoArrange)) }
                if ($now.ListVisible -ne $last.ListVisible) { Write-Host ($stamp + ('列表窗口可见 {0} → {1}' -f $last.ListVisible, $now.ListVisible)) }
                if ($now.HideIconsReg -ne $last.HideIconsReg) { Write-Host ($stamp + ('注册表 HideIcons {0} → {1}' -f $last.HideIconsReg, $now.HideIconsReg)) }
                if ($now.Count -eq $last.Count -and $key -ne $lastKey) {
                    $old = $lastKey -split ';'
                    $new = $key -split ';'
                    $moved = 0
                    for ($i = 0; $i -lt $new.Count; $i++) { if ($old[$i] -ne $new[$i]) { $moved++ } }
                    Write-Host ($stamp + ('有 {0} 个图标的位置变了' -f $moved))
                }
            }
            $last = $now
            $lastKey = $key
        } catch {
            if ($connected) { Write-Host ($stamp + '读取失败（资源管理器可能正在重启）：' + $_.Exception.Message) }
            $connected = $false
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Host '观察结束。'
    return
}

# --------------------------------------------------------------------------- 读一遍，打印全貌

Write-Section '视图设置'
$summary = Get-ViewSummary $view
Write-Host ('图标个数          ：{0}' -f $summary.Count)
Write-Host ('格子（GetSpacing）：{0} × {1}' -f $summary.CellWidth, $summary.CellHeight)
Write-Host ('图标边长          ：{0} 像素（视图模式 {1}）' -f $summary.IconSize, $summary.ViewMode)
if ($summary.FlagsOk) { Write-Host ('视图标志          ：{0}' -f (Format-FolderFlags $summary.Flags)) } else { Write-Host '视图标志          ：读取失败' }
Write-Host ('自动排列          ：{0}' -f $summary.AutoArrange)
Write-Host ('注册表 HideIcons  ：{0}' -f $summary.HideIconsReg)

# 用桌面视图自带的脚本对象（Shell 视图的脚本对象，ShellFolderView）再读一遍同样的设置，和上面互相印证
# （两边不一致，说明 common.ps1 里 IFolderView2 的声明有误，以这一行为准）
try {
    $automation = $view.AutomationObject()
    if ($null -ne $automation) {
        Write-Host ('Shell 视图脚本对象的读数：FolderFlags = {0}，IconSize = {1}，CurrentViewMode = {2}' -f `
            (Format-FolderFlags ([long]$automation.FolderFlags)), $automation.IconSize, $automation.CurrentViewMode)
    } else {
        Write-Host 'Shell 视图脚本对象的读数：取不到这个对象'
    }
} catch {
    Write-Host ('Shell 视图脚本对象的读数：读取失败（' + $_.Exception.Message + '）')
}

Write-Section '图标（不打印名字）'
$icons = $view.ReadIcons($true)

# 经 Shell 读每一项的修改时间（推荐读法：属性 System.DateModified；读不到再用脚本接口的简便写法 ModifyDate），
# 按解析名对上号（解析名只在内存里用）
$modified = @{}
try {
    $shell = New-Object -ComObject Shell.Application
    foreach ($item in $shell.NameSpace(0).Items()) {
        $date = $null
        try { $date = $item.ExtendedProperty('System.DateModified') } catch { $date = $null }
        if (-not ($date -is [datetime])) { $date = $item.ModifyDate }
        $modified[[string]$item.Path] = $date
    }
} catch {
    Write-Host ('（读修改时间失败：' + $_.Exception.Message + '）')
}

$halfYearAgo = (Get-Date).AddDays(-183)
Write-Host ('{0,3}  {1,-8}  {2,-14}  {3,-14}  {4,5}  {5}' -f '#', '种类', '原始位置', '屏幕位置', '缩放', '修改时间')
foreach ($icon in $icons) {
    $when = '读不到'
    $compareName = $icon.NameForCompare()
    if ($null -ne $compareName -and $modified.ContainsKey($compareName)) {
        $date = $modified[$compareName]
        if ($date -is [datetime] -and $date.Year -ge 1980) {
            if ($date -lt $halfYearAgo) { $when = '有，半年以上没改' } else { $when = '有，半年之内改过' }
        } else {
            $when = '没有（空值）'
        }
    }
    $position = '读取失败 0x{0:X8}' -f $icon.PositionResult
    if ($icon.PositionResult -eq 0) { $position = '({0},{1})' -f $icon.RawX, $icon.RawY }
    $dpi = [DdmProbe.WindowInfo]::DpiAt($icon.ScreenX, $icon.ScreenY)
    Write-Host ('{0,3}  {1,-8}  {2,-14}  {3,-14}  {4,5}  {5}' -f $icon.Index, $icon.KindText(), $position, ('({0},{1})' -f $icon.ScreenX, $icon.ScreenY), $dpi, $when)
}

Write-Section '汇总'
$groups = $icons | Group-Object { $_.KindText() }
foreach ($group in $groups) { Write-Host ('{0,-8} {1} 个' -f $group.Name, $group.Count) }
$bin = @($icons | Where-Object { $_.IsRecycleBin })
if ($bin.Count -eq 1) {
    Write-Host ('回收站：找到了，是图标 #{0}，屏幕位置 ({1},{2})' -f $bin[0].Index, $bin[0].ScreenX, $bin[0].ScreenY)
} elseif ($bin.Count -eq 0) {
    Write-Host '回收站：桌面上没有找到（可能被用户隐藏了，也可能是识别办法不对）'
} else {
    Write-Host ('回收站：找到了 {0} 个，不正常' -f $bin.Count)
}
$failed = @($icons | Where-Object { $_.PositionResult -ne 0 })
Write-Host ('位置读取失败的图标：{0} 个' -f $failed.Count)
$duplicates = @($icons | Group-Object { '{0},{1}' -f $_.RawX, $_.RawY } | Where-Object { $_.Count -gt 1 })
Write-Host ('位置完全相同的图标：{0} 组' -f $duplicates.Count)
Write-Host ''
Write-Host '下一步：运行 03-overlay.ps1，看红框 / 绿框哪一个正好套住图标（验证清单 V02）。'
