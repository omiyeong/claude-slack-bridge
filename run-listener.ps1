# 计划任务的入口：监听程序退出后 10 秒重启
. (Join-Path $PSScriptRoot 'lib\common.ps1')
while ($true) {
    $p = Start-Process powershell -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $PSScriptRoot 'listener.ps1')) `
        -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $script:LogDir 'listener.err')
    $p.WaitForExit()
    Write-Log 'listener' "监听程序退出，代码 $($p.ExitCode)，10 秒后重启"
    Start-Sleep -Seconds 10
}
