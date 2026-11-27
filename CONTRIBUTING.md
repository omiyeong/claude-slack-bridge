# 参与贡献

欢迎提 issue 和 PR。动手前先读 [AGENTS.md](AGENTS.md)，那里是这个项目踩过的坑，人和 AI 都照它来。

## 原则

- **零依赖**：只用 Windows PowerShell 5.1 和 .NET Framework 自带的东西，不引入模块、Python、Node。
- **一个进程连 Slack**：hook 只写 spool，Slack、状态文件、打字都只在 `listener.ps1` 里做。
- **显式优于聪明**：代码保持直白，少用隐式魔法，方便人和 AI 看懂、改对。

## 开发流程

1. Fork 后从 `main` 建分支。
2. 改完跑检查，必须通过（CI 也会跑同一个脚本）：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\check.ps1
   ```

   它检查所有 `.ps1` 能被解析、保存为带 BOM 的 UTF-8。编辑器按 [.editorconfig](.editorconfig) 设置就不会出错。

3. 手动验证：按 [README](README.md#改代码后重启) 重启 listener，用一个**临时测试会话**走一遍改动涉及的流程，不要拿正在干活的会话测打字。
4. 提 PR，写清楚改了什么、怎么验证的。

## 提交信息

格式 `[TAG] 中文描述`，一次提交只用一个 TAG，多类改动拆开提交：

| TAG | 用于 |
|---|---|
| `ADD` | 新功能 |
| `FIX` | 修 bug |
| `UPDATE` | 改进已有功能 |
| `REFACTOR` | 重构，行为不变 |
| `DEL` | 删除功能或文件 |
| `DOCS` | 文档 |
| `STYLE` | 格式 |
| `TEST` | 测试 |
| `CHORE` | 构建、CI、配置 |

## 不要提交

token、`.env`、`%USERPROFILE%\.claude-slack-bridge\` 下的任何运行数据（状态、spool、日志里都有你的会话内容）。
