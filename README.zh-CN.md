# codex-retry-watcher

<img src="icon/icon-preview.png" width="120" align="right" alt="app icon">

一个 macOS 菜单栏小工具:Codex Desktop 报

> Selected model is at capacity. Please try a different model.

的时候,自动帮你按下那条错误旁边的 **Retry**。

用辅助功能(Accessibility)API 直接"按"按钮:不移动鼠标、不抢焦点,
Codex 窗口可以在后台或者被别的窗口盖住。

[English](README.md)

## 为什么改配置解决不了

`Selected model is at capacity` 是 `codex` 内核里的**终态错误**,
和 `QuotaExceeded`、`RetryLimit` 并列在同一组 error variant 里
(字符串在 `ChatGPT.app/Contents/Resources/codex` 二进制里,不在前端 JS bundle)。
它不进重试预算,所以 `request_max_retries` / `stream_max_retries`
(它们覆盖 429、5xx 和流断连)对它无效。

上游 [openai/codex#22390](https://github.com/openai/codex/issues/22390)
要的正是这个能力("带 backoff 地重试瞬时容量错误并保留任务状态"),至今仍是 open。
在它落地之前,按按钮是唯一的自动化点。

## 安装

只需要 Xcode Command Line Tools(`xcode-select --install`),无其他依赖。

```bash
git clone https://github.com/tidingman/codex-retry-watcher.git
cd codex-retry-watcher
bash build.sh
```

编译并安装到 `/Applications/CodexRetryWatcher.app`。

**必须**装在 `/Applications`:系统设置的辅助功能列表通过 Finder
文件选择器添加 app,而它不显示隐藏目录 —— 放在 `~/.local/share`
之类的位置你根本选不到。

## 授权辅助功能

启动 app,然后打开 **系统设置 › 隐私与安全性 › 辅助功能**,
打开 `CodexRetryWatcher`。列表里没有它就点 **+**,从 `/Applications` 里选
(文件选择器里 `Cmd+Shift+G` 输入 `/Applications` 最快)。

看日志确认 —— app 会记录每一次权限状态变化:

```bash
tail -f ~/.local/share/codex-retry-watcher/watcher.log
```

出现 `accessibility permission OK` 就好了。没权限时菜单栏图标也会变成感叹号三角。

## 两个值得知道的坑

这两个都实打实耗了调试时间,所以写在这里而不是埋在 commit 里。

### 每次重新编译都会静默失去授权

`build.sh` 用 ad-hoc 签名(`codesign -s -`),没有证书身份,
所以 macOS TCC 只能按二进制的 **cdhash** 匹配 ——
每次重新编译它就成了"另一个 app",授权不再适用。
而系统设置里那条旧记录的开关**看着还是开的**(列表显示的是 bundle 名字),
所以看起来已授权,实际 app 什么都读不到。

**把开关关掉再打开没用。** 那只是把陈旧的 cdhash 记录重新置为允许。
必须让 TCC 忘掉旧条目:

- 点 **−** 移除 `CodexRetryWatcher`,再点 **+** 重新添加;或者
- ```bash
  tccutil reset Accessibility local.codex-retry-watcher
  ```

不用重启 app —— 每次扫描都会重新检查权限。

要彻底摆脱这个循环,用自签的 code signing 证书替代 ad-hoc 签名
(钥匙串访问 → 证书助理 里创建一张,然后把 `build.sh` 里的 `--sign -`
换成 `--sign "证书名"`)。TCC 会记住证书身份,重建也不掉。

### 别用终端跑 `--dump` 判断权限

TCC 把辅助功能权限归属到**责任进程(responsible process)**。
从 shell 直接执行 bundle 里的可执行文件时,责任进程是你的**终端**,
所以 `--dump` 反映的是终端有没有权限,而不是 app 有没有 ——
即使 app 工作得很好,它也会报 `no accessibility permission`。

要以 app 自己的身份查看无障碍树,用菜单里的
**导出无障碍树(诊断)**,它在 app 进程内执行并写出 `ax-dump.txt`。

## 菜单栏状态

| 图标 | 含义 |
|---|---|
| 顺时针箭头 | 监控中 |
| 双箭头循环 + 数字 | 检测到容量错误,正在重试(数字=第几次) |
| 暂停符号 | 已暂停(菜单里关掉了自动重试) |
| 感叹号三角 | 未授权辅助功能,读不到按钮 |
| 月亮 | Codex Desktop 未运行 |
| 八边形叉 | 连续重试仍未恢复,已放弃(只有设了 `--max-consecutive N` 才可能出现) |

菜单里可以:**开关自动重试(即停止/启动监听)**、切换试运行、立即重试一次、
导出无障碍树诊断、打开日志。

## 护栏

不会无限刷服务端:

| 行为 | 默认 | 参数 |
|---|---|---|
| 只在同一窗口出现 `at capacity` 时才按 | 是 | `--trigger <文本>` / `--any-retry` |
| 扫描间隔 | 3s | `--interval` |
| 按下后冷却 | 10s | `--cooldown` |
| 连续按几次仍不恢复就放弃并发通知 | 关闭 —— 无限重试 | `--max-consecutive N` |
| 匹配的按钮文案 | `retry`,`try again`,`重试`,`再试一次` | `--button "retry,resume"` |

默认永不放弃:只要错误还在屏幕上、监听是开着的,它就一直按(每个冷却周期按一次)。
想让它按 N 次后停下并通知你,传 `--max-consecutive N`;想降低频率,把 `--cooldown` 调大。
一旦某次扫描不再看到该错误,计数自动归零。
菜单里的"立即重试一次"不受 trigger、冷却和放弃状态限制,也不计入连续计数。

`--headless` 完全不要 UI(只写日志),`--help` 看全部参数。

## 开机自启

菜单栏 app 用登录项最自然:**系统设置 › 通用 › 登录项与扩展 › 登录时打开**,
点 **+** 选 `/Applications/CodexRetryWatcher.app`。

想要崩了自动拉起就用 LaunchAgent:

```bash
cp local.codex-retry-watcher.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/local.codex-retry-watcher.plist
```

## 实现

- `AX.swift` —— 无障碍树访问与匹配。给 Codex 进程设
  `AXManualAccessibility`,这是让 Chromium/Electron 向客户端暴露网页无障碍树的开关。
  遍历带节点数、深度和时间预算。
- `Watcher.swift` —— 扫描/按下引擎,跑在自己的 dispatch queue 上,
  慢的树遍历不会卡住菜单栏。通过 `AXUIElementPerformAction` + `AXPress` 按下。
- `MenuBar.swift` —— `NSStatusItem` UI。设了 `LSUIElement`,没有 Dock 图标;
  状态图标用 SF Symbols 模板,自动跟随明暗主题。
- `icon/MakeIcon.swift` —— 用 CoreGraphics 按每个需要的尺寸分别绘制 app 图标
  (而不是缩放一张大图),16pt 下自动去掉闪电免得糊成一团。
  `bash icon/make-icon.sh` 重新生成。

只有当 Retry 按钮和触发文案出现在**同一个窗口**里才会按。每次扫描会遍历
Codex 暴露的所有窗口，并按下每个符合条件的 Retry 按钮，所以多个 Codex
窗口或多个同时报错的对话都可以一起处理。

默认按钮文案已经包含中文的 `重试` 和 `再试一次`。如果你的 Codex 版本连错误
提示文本也本地化了,可以用 `--trigger` 指定实际显示的文本,或者用
`--any-retry` 跳过错误文本匹配。

## 限制

- 只支持 macOS,且绑定 Codex Desktop 的界面。如果 OpenAI 改了那个错误视图的结构,
  文案匹配可能要调整 —— `--button` 和 `--trigger` 就是为了让你不用重新编译也能适配。
- 依赖 Electron 暴露网页无障碍树。目前确实暴露
  (已验证 `AXButton :: Retry` 可达、`AXPress` 有效),但这不是契约。
- ad-hoc 签名带来上面那个"重建就要重新授权"的循环。
- 重试不会变出容量。如果模型真的饱和,它会一直按一个一直失败的按钮 ——
  换模型仍然是真正的解法。想让它放弃并告诉你,用 `--max-consecutive N`。

在 macOS 26.5.1 (arm64)、Swift 6.3.2、Codex Desktop 26.901.51231 上测试。

## 许可

MIT,见 [LICENSE](LICENSE)。
