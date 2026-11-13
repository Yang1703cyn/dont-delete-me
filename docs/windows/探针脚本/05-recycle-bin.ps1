# ============================================================================
# 未经运行。
# 这个文件是在一台 Mac 上写的，没有在任何 Windows 电脑上运行过，只做过人工通读和一次独立审阅。
# ============================================================================
#
# 探针 05：回收站（验证清单 V06）
#
# 要回答的问题：一个图标从桌面消失时，怎样分辨它是"进了回收站"、"挪去了别处"还是"被永久删除了"。
#
# 做什么：
#   1. 在桌面图标里找回收站，打印它的位置（不打印别的图标的任何信息）；
#   2. 读回收站里的项目数；
#   3. 在桌面上新建一个自己的临时文本文件（名字以"别删我-测试-"开头）；
#   4. 等你对这个临时文件做一个动作，期间持续记录：文件还在不在、桌面视图里还有没有它、回收站项目数、鼠标主键；
#   5. 到回收站里只找这一个临时文件，读它的"原位置"和"删除时间"；
#   6. 给出结论。临时文件如果还在桌面上，脚本会把它删掉；如果进了回收站，脚本不替你清理（不清空回收站）。
#
# 脚本只动自己新建的那一个临时文件。读回收站时只比对这个临时文件的名字，不打印、不保存里面别的东西的名字。
#
# 运行之前请注意两点：
#   · 先关掉桌面的"自动排列图标"（右键 → 查看）。开着的话，新建和删掉临时文件时，别的图标会跟着重新排位。
#   · 如果开着 Windows 安全中心的"受控文件夹访问"，往桌面写文件会被拦下，脚本会说明后结束，不会改任何设置。
#
# 用法（建议跑三遍，每遍做一种动作；每遍最多 90 秒，动作完成后会自己提前结束）：
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\05-recycle-bin.ps1
#     第一遍：把临时文件拖进回收站
#     第二遍：把临时文件拖进桌面上任意一个文件夹（或拖到别的窗口里）
#     第三遍：选中临时文件，按 Shift+Delete 永久删除
#   可选的第四遍：在"桌面图标设置"里取消勾选"回收站"后再跑一次，看开头是不是"没有找到回收站图标"（做完请勾回去）。
# 运行中按 Ctrl+C 可以中止；临时文件如果还在桌面上，请自己删掉（名字以"别删我-测试-"开头）。

param(
    [int]$Seconds = 90
)

# 出错时只打印文件名、行号和错误说明，不打印含用户名的完整路径
trap { Write-Host ('出错（{0} 第 {1} 行）：{2}' -f [IO.Path]::GetFileName([string]$_.InvocationInfo.ScriptName), $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message); exit 1 }

. "$PSScriptRoot\common.ps1"

function Test-InDesktopView {
    param($View, [string]$Path)
    try {
        return (@($View.ReadIcons($true) | Where-Object { $_.NameForCompare() -eq $Path }).Count -gt 0)
    } catch {
        return $false
    }
}

Write-Section '回收站图标'
$view = [DdmProbe.DesktopView]::Open()
$icons = $view.ReadIcons($true)
$spacing = $view.Spacing()
$bin = @($icons | Where-Object { $_.IsRecycleBin })
if ($bin.Count -ge 1) {
    Write-Host ('桌面上有回收站图标：#{0}，屏幕位置 ({1},{2})，格子 {3}×{4}' -f $bin[0].Index, $bin[0].ScreenX, $bin[0].ScreenY, $spacing[1], $spacing[2])
} else {
    Write-Host '桌面上没有找到回收站图标（被隐藏了，或者识别办法不对）。后面的步骤照常进行。'
}

Write-Section '回收站里的项目数'
$countAtStart = [DdmProbe.RecycleBin]::ItemCount()
Write-Host ('SHQueryRecycleBin：{0} 项（{1}）' -f $countAtStart, [DdmProbe.RecycleBin]::LastNote)

Write-Section '新建临时文件'
$desktopDirectory = [Environment]::GetFolderPath('DesktopDirectory')
$name = '别删我-测试-' + ([Guid]::NewGuid().ToString('N').Substring(0, 6)) + '.txt'
$path = Join-Path $desktopDirectory $name
try {
    Set-Content -LiteralPath $path -Value '「别删我」探针脚本新建的临时文件，可以放心删除。' -Encoding UTF8
} catch {
    # 不打印系统给的报错原文：里面带着含用户名的完整路径
    Write-Host '在桌面上新建临时文件失败（常见原因：开着"受控文件夹访问"）。脚本到此结束，没有改动任何东西。'
    return
}

$clock = [System.Diagnostics.Stopwatch]::StartNew()
$appeared = $false
while ($clock.Elapsed.TotalSeconds -lt 8 -and -not $appeared) {
    Start-Sleep -Milliseconds 200
    $appeared = Test-InDesktopView $view $path
}
$appearedText = '仍没有出现'
if ($appeared) { $appearedText = '出现了' }
Write-Host ('临时文件「{0}」已建在桌面上；{1:F1} 秒后它在桌面视图里{2}。' -f $name, $clock.Elapsed.TotalSeconds, $appearedText)

Write-Section ('请在 {0} 秒内对这个临时文件做一个动作（拖进回收站 / 拖进文件夹 / Shift+Delete）' -f $Seconds)
$clock.Restart()
$lastDown = $false
$lastExists = $true
$lastInView = $appeared
$lastCount = $countAtStart
$goneSince = $null
while ($clock.Elapsed.TotalSeconds -lt $Seconds) {
    $stamp = '[{0,7:F0} 毫秒] ' -f $clock.Elapsed.TotalMilliseconds

    $down = [DdmProbe.WindowInfo]::PrimaryButtonDown()
    if ($down -ne $lastDown) {
        $position = [DdmProbe.WindowInfo]::CursorPosition()
        $what = '松开'
        if ($down) { $what = '按下' }
        Write-Host ($stamp + ('鼠标主键{0}，位置 ({1},{2})，该处最上面：{3}' -f $what, $position[0], $position[1], [DdmProbe.WindowInfo]::SurfaceAt($position[0], $position[1])))
        $lastDown = $down
    }

    $exists = Test-Path -LiteralPath $path
    if ($exists -ne $lastExists) {
        Write-Host ($stamp + ('临时文件在原路径上：{0} → {1}' -f $lastExists, $exists))
        $lastExists = $exists
    }

    $inView = Test-InDesktopView $view $path
    if ($inView -ne $lastInView) {
        Write-Host ($stamp + ('桌面视图里有它：{0} → {1}' -f $lastInView, $inView))
        $lastInView = $inView
    }

    $count = [DdmProbe.RecycleBin]::ItemCount()
    if ($count -ne $lastCount) {
        Write-Host ($stamp + ('回收站项目数：{0} → {1}' -f $lastCount, $count))
        $lastCount = $count
    }

    if (-not $exists -and -not $inView) {
        if ($null -eq $goneSince) { $goneSince = $clock.Elapsed.TotalSeconds }
        elseif (($clock.Elapsed.TotalSeconds - $goneSince) -gt 2) { break }
    } else {
        $goneSince = $null
    }
    Start-Sleep -Milliseconds 50
}
Write-Host '（提示：如果拖动期间读图标被资源管理器卡住，上面"鼠标主键松开"的时刻会偏晚；准确的时刻请看探针 02。）'

Write-Section '到回收站里找这个临时文件'
$foundInBin = $false
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($name)
try {
    $shell = New-Object -ComObject Shell.Application
    foreach ($item in $shell.NameSpace(10).Items()) {      # 10 = 回收站
        $itemName = [string]$item.Name
        if ($itemName -eq $name -or $itemName -eq $baseName) {
            $foundInBin = $true
            $from = $item.ExtendedProperty('System.Recycle.DeletedFrom')
            $when = $item.ExtendedProperty('System.Recycle.DateDeleted')
            Write-Host ('找到了。"原位置"等于桌面文件夹：{0}' -f ([string]$from -eq $desktopDirectory))
            if ($when -is [datetime]) {
                Write-Host ('"删除时间"距现在：按本地时间算 {0:F0} 秒，按协调世界时算 {1:F0} 秒（哪个接近 0，它就是哪种时间）' -f `
                    ((Get-Date) - $when).TotalSeconds, ([datetime]::UtcNow - $when).TotalSeconds)
            } else {
                Write-Host ('"删除时间"读到的不是时间值，类型是：{0}' -f $(if ($null -eq $when) { '空' } else { $when.GetType().Name }))
            }
        }
    }
} catch {
    Write-Host ('枚举回收站失败：' + $_.Exception.Message)
}
if (-not $foundInBin) { Write-Host '回收站里没有它。' }

Write-Section '结论'
$stillThere = Test-Path -LiteralPath $path
$countAtEnd = [DdmProbe.RecycleBin]::ItemCount()
Write-Host ('回收站项目数：开始 {0}，结束 {1}' -f $countAtStart, $countAtEnd)
if ($stillThere) {
    Write-Host '临时文件还在桌面上（没有动它，或者动作被取消了）。'
    try {
        Remove-Item -LiteralPath $path -Force
        Write-Host '已删除这个临时文件。'
    } catch {
        Write-Host ('没能删掉这个临时文件，请自己删一下：桌面上的「{0}」。' -f $name)
    }
} elseif ($foundInBin) {
    Write-Host '→ 进了回收站：图标消失 + 回收站里有一项"原位置是桌面、名字相同"。'
    Write-Host '临时文件现在在回收站里，可以自己去回收站把它删掉；脚本不清空回收站。'
} elseif ($countAtEnd -gt $countAtStart) {
    Write-Host '→ 不确定：回收站项目数变多了，但里面没有找到这个名字（可能是别的东西刚好进了回收站，或者名字的比对方式不对）。'
} else {
    Write-Host '→ 没进回收站：图标消失，而回收站没有变化——它被挪去了别处，或者被永久删除了。'
    Write-Host '如果是挪进了某个文件夹，请自己把这个临时文件删掉。'
}
