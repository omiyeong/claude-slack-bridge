# 安装：注册登录时启动的计划任务，并打印要合并进 ~/.claude/settings.json 的 hooks 配置。
# 不会自动修改 settings.json。
param([switch]$RegisterTask)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$hook = ($root -replace '\\', '/') + '/hook.ps1'

if ($RegisterTask) {
    # 默认终端是 Windows Terminal 时，直接启动 powershell 会被它接管成可见窗口（-WindowStyle Hidden 无效），
    # 关掉窗口监听就停了。用无头 conhost 托管，不创建任何窗口
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' `
        -Argument ('--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $root 'run-listener.ps1'))
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    # Interactive：只在你登录时运行，这样才能操作桌面应用窗口和剪贴板
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'claude-slack-bridge' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Output '已注册计划任务 claude-slack-bridge（登录时启动）'
}

# /slack 命令文件：让输入框能补全它；真正的处理在 UserPromptSubmit hook
$commandsDir = Join-Path $env:USERPROFILE '.claude\commands'
if (-not (Test-Path $commandsDir)) { New-Item -ItemType Directory -Path $commandsDir | Out-Null }
Copy-Item (Join-Path $root 'commands\slack.md') (Join-Path $commandsDir 'slack.md') -Force
Write-Output "已安装 /slack 命令到 $commandsDir"

$cmd = { param($mode) "powershell -NoProfile -ExecutionPolicy Bypass -File `"$hook`" $mode" }
$snippet = [ordered]@{
    Stop              = @(@{ hooks = @(@{ type = 'command'; command = (& $cmd 'stop') }) })
    PermissionRequest = @(@{ hooks = @(@{ type = 'command'; command = (& $cmd 'permission'); timeout = 600 }) })
    Notification      = @(@{ hooks = @(@{ type = 'command'; command = (& $cmd 'notification') }) })
    UserPromptSubmit  = @(@{ hooks = @(@{ type = 'command'; command = (& $cmd 'prompt') }) })
}
Write-Output '把下面四项合并进 ~/.claude/settings.json 的 "hooks"（保留已有条目）：'
Write-Output ($snippet | ConvertTo-Json -Depth 10)
