# 把一段文字打进桌面应用某个会话的输入框并发送。由监听程序作为子进程调用，一次一条。
# 结果写到 ResultFile：ok 或 error:<原因>
param(
    [Parameter(Mandatory)] [string]$SessionId,
    [Parameter(Mandatory)] [string]$TextFile,
    [Parameter(Mandatory)] [string]$ResultFile
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false

function Write-Result([string]$Value) { [System.IO.File]::WriteAllText($ResultFile, $Value, $utf8) }

try {
    Add-Type -AssemblyName System.Windows.Forms
    if (-not ('BridgeWin' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BridgeWin {
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
'@
    }

    # 按程序路径找桌面应用主窗口，不按标题匹配，避免找到浏览器里的 Claude 标签页
    $app = Get-Process -Name claude -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 -and $_.Path -like '*\app\Claude.exe' } | Select-Object -First 1
    if (-not $app) { Write-Result 'error:桌面应用没有运行'; exit }

    $text = [System.IO.File]::ReadAllText($TextFile, $utf8)
    $saved = $null
    try { $saved = Get-Clipboard -Raw -ErrorAction SilentlyContinue } catch {}
    Set-Clipboard -Value $text

    try {
        Start-Process "claude://claude.ai/epitaxy/$SessionId"
        Start-Sleep -Milliseconds 2500
        if ([BridgeWin]::IsIconic($app.MainWindowHandle)) { [void][BridgeWin]::ShowWindowAsync($app.MainWindowHandle, 9) }
        $ws = New-Object -ComObject WScript.Shell
        [void]$ws.AppActivate($app.Id)
        Start-Sleep -Milliseconds 500
        if ([BridgeWin]::GetForegroundWindow() -ne $app.MainWindowHandle) { Write-Result 'error:没能把桌面应用切到前台'; exit }
        [System.Windows.Forms.SendKeys]::SendWait('^v')
        Start-Sleep -Milliseconds 400
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        Start-Sleep -Milliseconds 800
    } finally {
        if ($null -ne $saved) { Set-Clipboard -Value $saved }
    }
    Write-Result 'ok'
} catch {
    Write-Result ("error:" + $_.Exception.Message)
}
