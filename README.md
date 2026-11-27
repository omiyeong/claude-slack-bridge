# Claude 桌面会话 Slack 桥接

人离开电脑时，Claude 桌面应用里的会话停下来会发到 Slack 私信，每个会话一个 thread。在 thread 里回复，文字会打回电脑上同一个会话；选择题和授权用按钮答。只支持 Windows，全部用系统自带的 PowerShell 5.1，不装依赖。

设计说明见 `D:\liuxin\docs\Claude桌面会话Slack桥接设计.md`。

| 文件 | 作用 |
|---|---|
| `hook.ps1` | Claude hook 入口（`stop` / `permission` / `notification`），只写事件到 spool |
| `listener.ps1` | 常驻进程，唯一连 Slack 的地方：发通知、收回复、打字、处理按钮 |
| `run-listener.ps1` | 计划任务入口，监听程序退出后自动重启 |
| `lib\inject.ps1` | 打开指定会话、粘贴、回车 |
| `manifest.yml` | Slack 应用清单 |
| `install.ps1` | 注册计划任务，打印 hooks 配置 |

## 安装

1. Slack 后台 → Create New App → From a manifest，粘贴 `manifest.yml`，安装到工作区。
2. 记下 OAuth & Permissions 页的 Bot Token（`xoxb-`）。在 Basic Information → App-Level Tokens 生成一个带 `connections:write` 的 token（`xapp-`）。
3. 把 `.env.example` 复制成 `%USERPROFILE%\.claude-slack-bridge\.env`，填 token 和你的 Slack 用户 ID。
4. 先手动跑一次确认能连上，私信里应收到“桥接已启动”：

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File D:\liuxin\code\claude-slack-bridge\listener.ps1
```

5. `install.ps1 -RegisterTask` 注册登录时自启；把它打印的 hooks 片段合并进 `~/.claude/settings.json`。

运行数据（状态、spool、日志）在 `%USERPROFILE%\.claude-slack-bridge\`，不进仓库。
