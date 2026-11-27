# 安装：注册登录时启动的计划任务，并打印要合并进 ~/.claude/settings.json 的 hooks 配置。
# 不会自动修改 settings.json。
param([switch]$RegisterTask)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$hook = ($root -replace '\\', '/') + '/hook.ps1'

if ($RegisterTask) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $root 'run-listener.ps1'))
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    # Interactive：只在你登录时运行，这样才能操作桌面应用窗口和剪贴板
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'claude-slack-bridge' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Output '已注册计划任务 claude-slack-bridge（登录时启动）'
}

$cmd = { param($mode) "powershell -NoProfile -ExecutionPolicy Bypass -File `"$hook`" $mode" }
$snippet = [ordered]@{
    Stop              = @(@{ hooks = @(@{ type = 'command'; command = (& $cmd 'stop') }) })
    PermissionRequest = @(@{ hooks = @(@{ type = 'command'; command = (& $cmd 'permission'); timeout = 600 }) })
    Notification      = @(@{ hooks = @(@{ type = 'command'; command = (& $cmd 'notification') }) })
}
Write-Output '把下面三项合并进 ~/.claude/settings.json 的 "hooks"（保留已有条目）：'
Write-Output ($snippet | ConvertTo-Json -Depth 10)
