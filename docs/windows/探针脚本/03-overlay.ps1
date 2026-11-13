# ============================================================================
# 未经运行。
# 这个文件是在一台 Mac 上写的，没有在任何 Windows 电脑上运行过，只做过人工通读和一次独立审阅。
# ============================================================================
#
# 探针 03：画框的叠加窗口（验证清单 V02、V04、V05、V08、V09、V10、V13、V16、V19、V22）
#
# 做什么：开一个盖住整个屏幕、透明、点击穿透的窗口，在每个桌面图标的位置上画几种框，持续若干秒后自己关闭。
#         每 2 秒在终端里报告一次：它和桌面窗口谁在上面、它上面有几个窗口、在不在当前虚拟桌面、
#         图标中心那个点上"最上面的窗口"是谁。
#         全程只读，不移动图标。窗口从创建那一刻起就不抢焦点；除 -NoRedirectionBitmap 外都点击穿透。
#
#   红框 = 候选一：把读到的位置当作"格子的左上角"，图标图像在格子里水平居中
#   青框 = 候选三：同候选一，但图标边长按所在屏的缩放放大（缩放不是 100% 时才和红框不同）
#   绿框 = 候选二：把读到的位置当作"图标图像的左上角"
#   橙框 = 文字矩形的估算：从红框下沿到格子下沿
#   蓝框 = 整个格子（位置 + 格子大小）
#   黄色数字 = 图标序号（和 01-read-icons.ps1 打印的序号一致）
#
# 想提前结束：直接按 Esc；如果之前点过别处，先用 Alt+Tab 切回运行这个脚本的 PowerShell 窗口再按。
#   （窗口开着的时候 PowerShell 要等它关掉才响应 Ctrl+C，所以 Ctrl+C 没用。实在不行，直接关掉这个 PowerShell 窗口。）
#
# 用法：
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\03-overlay.ps1                  # 沉底（默认）
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\03-overlay.ps1 -Mode follow     # 沉底 + 显示桌面时上浮
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\03-overlay.ps1 -Mode owner      # 属主设为桌面窗口
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\03-overlay.ps1 -Mode topmost    # 置顶（拖拽层）
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\03-overlay.ps1 -NoRedirectionBitmap
#   以上都可以加 -Seconds N（默认 40）。
#
# 每一项要看什么，见 ../上机验证清单.md 的对应条目。

param(
    [ValidateSet('bottom', 'follow', 'owner', 'topmost')]
    [string]$Mode = 'bottom',
    [int]$Seconds = 40,
    [switch]$NoRedirectionBitmap
)

# 出错时只打印文件名、行号和错误说明，不打印含用户名的完整路径
trap { Write-Host ('出错（{0} 第 {1} 行）：{2}' -f [IO.Path]::GetFileName([string]$_.InvocationInfo.ScriptName), $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message); exit 1 }

. "$PSScriptRoot\common.ps1"

Write-Section ('叠加窗口，模式 {0}，持续 {1} 秒' -f $Mode, $Seconds)
switch ($Mode) {
    'bottom'  { Write-Host '沉底：窗口放在所有普通窗口之下。请依次试：①看框有没有套住图标；②在框上单击、右键、拖出选框，看是否和平时一样；' ; Write-Host '      ③把任意一个普通窗口拖到图标上，看框是否被盖住；④按 Win+D（显示桌面），看框还在不在；⑤按 Win+Ctrl+→ 切到另一个虚拟桌面再切回来。' }
    'follow'  { Write-Host '沉底 + 上浮：平时沉底；发现桌面被提到自己上面时把自己提上来。请按 Win+D 两次，再打开一个普通窗口，看框的表现和终端里的 [follow] 行。' }
    'owner'   { Write-Host '属主法：窗口建好后把它的属主改成桌面窗口（开头那行"实际属主"应当是 Progman 或 WorkerW）。请按 Win+D、切换虚拟桌面、打开普通窗口，看框的表现。' ; Write-Host '      注意：这种模式下两边的输入是连在一起的；如果脚本卡住、桌面也跟着没反应，直接关掉这个 PowerShell 窗口即可恢复。' }
    'topmost' { Write-Host '置顶：窗口在所有普通窗口之上。请真的拖起一个自己的测试图标，看框和跟着鼠标的半透明图标（拖影）谁在上面；再看任务栏、开始菜单会不会盖住框。' }
}
if ($NoRedirectionBitmap) {
    Write-Host '-NoRedirectionBitmap：窗口不用分层样式，改带"不分配后台画布"的样式（系统合成引擎要求的那种），什么都不画。'
    Write-Host '      请在桌面上照常单击、拖选框：如果点不动桌面，说明这种窗口点不穿——这正是要验证的事；按 Esc 结束即可恢复。'
}
Write-Host ''

[DdmProbe.OverlayForm]::RunFor($Mode, $Seconds, [bool]$NoRedirectionBitmap)
