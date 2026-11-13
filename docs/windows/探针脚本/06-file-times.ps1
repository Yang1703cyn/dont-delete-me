# ============================================================================
# 未经运行。
# 这个文件是在一台 Mac 上写的，没有在任何 Windows 电脑上运行过，只做过人工通读和一次独立审阅。
# ============================================================================
#
# 探针 06：文件时间（验证清单 V14）
#
# 要回答的问题：
#   1. 这台电脑上"最近访问时间"会不会更新（它是不是一个能用的依据）；
#   2. 经 Shell 读桌面各项的"修改时间"时，快捷方式、文件夹、系统图标各是什么表现。
#
# 做什么：
#   · 在系统的临时文件夹里（不是桌面）新建一个自己的小文件，把它的访问时间拨回两天前，读一下它，看访问时间变没变，然后删掉它。
#     （NTFS 只在上次访问时间比现在早一个小时以上时才更新它，所以不拨回去的话，刚建好的文件读了也不会变。）
#   · 读系统里控制"是否更新访问时间"的那个设置（只读）；
#   · 经 Shell 读桌面每一项的修改时间，用两种读法各读一次，只按种类汇总成几个数字，不打印任何名字。
#     推荐读法：属性 System.DateModified（方案 §6.2 推荐的读法）；对照：脚本接口的简便写法 ModifyDate。
#
# 用法：
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\06-file-times.ps1
# 运行中按 Ctrl+C 可以中止。

# 出错时只打印文件名、行号和错误说明，不打印含用户名的完整路径
trap { Write-Host ('出错（{0} 第 {1} 行）：{2}' -f [IO.Path]::GetFileName([string]$_.InvocationInfo.ScriptName), $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message); exit 1 }

. "$PSScriptRoot\common.ps1"

Write-Section '最近访问时间会不会更新'
$temporary = Join-Path $env:TEMP ('ddm-probe-' + [Guid]::NewGuid().ToString('N') + '.txt')
$created = $false
try {
    Set-Content -LiteralPath $temporary -Value 'probe'
    $created = $true
    # 只动自己这个临时文件：把访问时间拨回两天前
    (Get-Item -LiteralPath $temporary).LastAccessTimeUtc = [datetime]::UtcNow.AddDays(-2)
    $before = Get-Item -LiteralPath $temporary
    $accessBefore = $before.LastAccessTimeUtc
    $writeBefore = $before.LastWriteTimeUtc
    Write-Host ('拨回之后读到的访问时间离现在 {0:F1} 小时（应当约 48；不是的话，下面这一行的结论作废——可能是杀毒软件刚扫过它）' -f `
        ([datetime]::UtcNow - $accessBefore).TotalHours)
    Start-Sleep -Seconds 1
    $null = Get-Content -LiteralPath $temporary
    Start-Sleep -Milliseconds 500
    $after = Get-Item -LiteralPath $temporary
    Write-Host ('读取文件内容之后，访问时间变了：{0}（变了的话，新的访问时间离现在 {1:F0} 秒）' -f `
        ($after.LastAccessTimeUtc -ne $accessBefore), ([datetime]::UtcNow - $after.LastAccessTimeUtc).TotalSeconds)
    Write-Host ('读取文件内容之后，修改时间变了：{0}（应当是 False）' -f ($after.LastWriteTimeUtc -ne $writeBefore))
} catch {
    # 不打印系统给的报错原文：里面带着含用户名的临时文件夹路径
    Write-Host '这一项没做成（在系统临时文件夹里新建或读取自己的临时文件失败），略过。'
} finally {
    if ($created) {
        try { Remove-Item -LiteralPath $temporary -Force } catch { Write-Host '（没能删掉自己的临时文件；它在系统临时文件夹里，名字以 ddm-probe- 开头。）' }
    }
}
Write-Host '（这只说明系统盘上的表现。别的盘、别的文件系统可能不同。）'

Write-Section '系统设置：是否更新访问时间'
try {
    $value = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'NtfsDisableLastAccessUpdate' -ErrorAction Stop).NtfsDisableLastAccessUpdate
    $number = [long]$value
    if ($number -lt 0) { $number += 4294967296 }
    $notes = @()
    if ($number -band 0x1) { $notes += '停用访问时间更新' } else { $notes += '没有设"停用"位' }
    if ($number -band 0x2) { $notes += '由系统管理（按启动卷大小自动决定）' } else { $notes += '由用户管理' }
    Write-Host ('NtfsDisableLastAccessUpdate = 0x{0:X8}：{1}' -f $number, ($notes -join '；'))
} catch {
    Write-Host ('读不到这个设置：' + $_.Exception.Message)
}
# 外部命令往错误输出里写东西时，"遇错即停"的设置会把它当成异常；所以这一小段临时放宽。
$previousPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $output = & fsutil behavior query disablelastaccess 2>&1 | ForEach-Object { [string]$_ }
    Write-Host ('fsutil 的说法：{0}' -f ($output -join ' '))
} catch {
    Write-Host 'fsutil 没能运行（可能需要管理员权限），略过。'
} finally {
    $ErrorActionPreference = $previousPreference
}

Write-Section '桌面各项的修改时间（经 Shell 读；只汇总，不打印名字）'
$halfYearAgo = (Get-Date).AddDays(-183)
$stats = @{}
try {
    $shell = New-Object -ComObject Shell.Application
    foreach ($item in $shell.NameSpace(0).Items()) {
        $kind = '文件'
        if (-not $item.IsFileSystem) { $kind = '系统图标' }
        elseif ($item.IsLink) { $kind = '快捷方式' }
        elseif ($item.IsFolder) { $kind = '文件夹（含压缩包）' }
        if (-not $stats.ContainsKey($kind)) { $stats[$kind] = @{ Total = 0; Recommended = 0; RecommendedOld = 0; Simple = 0 } }
        $stats[$kind].Total++

        $recommended = $null
        try { $recommended = $item.ExtendedProperty('System.DateModified') } catch { $recommended = $null }
        if ($recommended -is [datetime] -and $recommended.Year -ge 1980) {
            $stats[$kind].Recommended++
            if ($recommended -lt $halfYearAgo) { $stats[$kind].RecommendedOld++ }
        }
        $simple = $null
        try { $simple = $item.ModifyDate } catch { $simple = $null }
        if ($simple -is [datetime] -and $simple.Year -ge 1980) { $stats[$kind].Simple++ }
    }
    foreach ($kind in $stats.Keys) {
        $row = $stats[$kind]
        Write-Host ('{0,-10} 共 {1} 个；推荐读法读得到 {2} 个（其中半年以上没改的 {3} 个）；简便写法读得到 {4} 个' -f `
            $kind, $row.Total, $row.Recommended, $row.RecommendedOld, $row.Simple)
    }
    Write-Host '（这里列的是桌面这个文件夹里的全部项目，可能比桌面上实际显示的图标多——系统图标有些是被隐藏的。）'
} catch {
    Write-Host ('读取失败：' + $_.Exception.Message)
}
