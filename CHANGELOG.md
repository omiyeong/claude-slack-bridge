# 更新记录

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [0.1.0] - 2026-11-27

第一个公开版本。

### 新增

- 离开电脑一段时间后，会话停下、选择题、授权请求发到 Slack 私信，每个会话一个 thread。
- 在 thread 里回复，文字打回电脑上同一个会话；会话在跑时排队，送达后标 ✅。
- 选择题（单选、多选、自己填）和工具授权在 Slack 里用按钮作答，9 分钟没答交回桌面弹窗。
- `/slack` 命令：新开 thread，发最近 5 条消息，之后这个会话停下都发到 Slack。
- 私信里发 `列表` 查看所有在等你的会话。
- thread 标题为 `项目.会话名`，worktree 归到所在仓库。
- 计划任务用无头 `conhost` 后台运行，退出后自动重启。
- 打字前确认没有在用键鼠、会话没有开着的弹窗。

[0.1.0]: https://github.com/omiyeong/claude-slack-bridge/releases/tag/v0.1.0
