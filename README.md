# codex-retry-watcher

<img src="icon/icon-preview.png" width="120" align="right" alt="app icon">

A tiny macOS menu bar app that presses **Retry** for you when Codex Desktop
says:

> Selected model is at capacity. Please try a different model.

It uses the Accessibility API to press the button *in place* — it never moves
your mouse, never steals focus, and the Codex window can stay in the
background or be covered by other windows.

[中文说明](README.zh-CN.md)

## Why a config option can't fix this

`Selected model is at capacity` is a **terminal error** inside the `codex`
core, sitting alongside `QuotaExceeded` and `RetryLimit` in the same set of
error variants (you can find the string in
`ChatGPT.app/Contents/Resources/codex`, not in the app's JavaScript bundle).
It never enters the retry budget, so `request_max_retries` and
`stream_max_retries` — which cover 429s, 5xxs and dropped streams — do not
apply to it.

Upstream, [openai/codex#22390](https://github.com/openai/codex/issues/22390)
asks for exactly this behaviour ("retry transient capacity errors with backoff
and retained task state") and is still open. Until that lands, pressing the
button is the only automation point.

## Install

Requires Xcode Command Line Tools (`xcode-select --install`) — no other
dependencies.

```bash
git clone https://github.com/tidingman/codex-retry-watcher.git
cd codex-retry-watcher
bash build.sh
```

This builds and installs `/Applications/CodexRetryWatcher.app`.

It **must** live in `/Applications`: the Accessibility list in System Settings
adds apps through a Finder file picker, which will not show hidden
directories, so an app kept somewhere like `~/.local/share` simply cannot be
selected there.

## Grant Accessibility access

Launch the app, then open **System Settings › Privacy & Security ›
Accessibility** and enable `CodexRetryWatcher`. If it isn't listed, click
**+** and pick it from `/Applications` (`Cmd+Shift+G` → `/Applications` is the
fastest route).

Confirm it worked by watching the log — the app records every permission
transition:

```bash
tail -f ~/.local/share/codex-retry-watcher/watcher.log
```

`accessibility permission OK` means you're done. The menu bar icon also turns
into a warning triangle whenever permission is missing.

## Two gotchas worth knowing

Both cost me real debugging time, so they're documented here rather than
buried in a commit message.

### Rebuilding revokes Accessibility access, silently

`build.sh` signs the app ad-hoc (`codesign -s -`), which carries no
certificate identity. macOS TCC therefore matches the app by its binary's
**cdhash** — so every recompile makes it a *different* app and the grant stops
applying. The switch in System Settings still shows the old entry as enabled
(the list displays the bundle's name), so it looks authorised while the app
silently reads nothing.

**Toggling the switch off and on does not fix it.** That only re-approves the
stale cdhash record. You have to make TCC forget the old entry:

- click **−** to remove `CodexRetryWatcher`, then **+** to add it again, or
- ```bash
  tccutil reset Accessibility local.codex-retry-watcher
  ```

No app restart needed — permission is re-checked on every scan.

To avoid this loop entirely, sign with a self-signed code signing certificate
instead of ad-hoc (create one in Keychain Access → Certificate Assistant, then
replace `--sign -` in `build.sh` with `--sign "Your Cert Name"`). TCC then
remembers the certificate identity and survives rebuilds.

### Don't use `--dump` from a terminal to test permission

TCC attributes Accessibility access to the **responsible process**. Running
the bundle's executable directly from a shell makes your *terminal* the
responsible process, so `--dump` reports whether the terminal has access — not
whether the app does. It will say `no accessibility permission` even when the
app is working perfectly.

To inspect the tree as the app itself, use the **导出无障碍树(诊断)** /
*Export accessibility tree* item in the menu; it runs inside the app process
and writes `ax-dump.txt`.

## Menu bar states

| Icon | Meaning |
|---|---|
| Clockwise arrow | Watching |
| Two-arrow loop + number | Capacity error detected, retrying (number = attempt) |
| Pause | Paused (auto-retry switched off in the menu) |
| Warning triangle | No Accessibility permission — cannot read buttons |
| Moon | Codex Desktop isn't running |
| Octagon with an X | Gave up after repeated retries didn't recover (only reachable with `--max-consecutive N`) |

The menu can toggle auto-retry — i.e. stop/start watching — toggle dry-run,
retry once immediately, export the accessibility tree for diagnosis, and open
the log.

## Guardrails

It won't hammer the backend:

| Behaviour | Default | Flag |
|---|---|---|
| Only presses when `at capacity` appears in the same window | on | `--trigger <text>` / `--any-retry` |
| Scan interval | 3s | `--interval` |
| Cooldown after a press | 10s | `--cooldown` |
| Give up (and notify) after N presses without recovery | off — retries indefinitely | `--max-consecutive N` |
| Button labels matched | `retry`, `try again`, `重试`, `再试一次` | `--button "retry,resume"` |

By default it never gives up: as long as the error is on screen and watching is
on, it keeps pressing (one press per cooldown). Pass `--max-consecutive N` if
you'd rather it stop and notify you after N attempts. Raise `--cooldown` to
press less often. The counter resets as soon as a scan no longer sees the
error. *Retry once immediately* from the menu ignores the trigger, cooldown and
give-up state, and doesn't count toward the limit.

Run with `--headless` for no UI at all (logs only), or `--help` for the full
flag list.

## Run at login

For a menu bar app, a login item is the natural choice: **System Settings ›
General › Login Items & Extensions › Open at Login**, click **+** and pick
`/Applications/CodexRetryWatcher.app`.

If you want it restarted automatically when it crashes, use the LaunchAgent
instead:

```bash
cp local.codex-retry-watcher.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/local.codex-retry-watcher.plist
```

## How it works

- `AX.swift` — Accessibility tree access and matching. Sets
  `AXManualAccessibility` on the Codex process, which is the opt-in that makes
  Chromium/Electron publish its web accessibility tree to a client at all.
  Walks the tree under node, depth and wall-clock budgets.
- `Watcher.swift` — scan/press engine on its own dispatch queue, so a slow
  tree walk can never stall the menu bar. Presses via `AXUIElementPerformAction`
  with `AXPress`.
- `MenuBar.swift` — `NSStatusItem` UI. `LSUIElement` is set, so there's no Dock
  icon; the status icon uses SF Symbols templates and follows light/dark
  automatically.
- `icon/MakeIcon.swift` — draws the app icon with CoreGraphics at each required
  size (rather than downscaling one bitmap), and drops the bolt at 16pt where
  fine detail turns to mush. Regenerate with `bash icon/make-icon.sh`.

A press only happens when a Retry-style button and the trigger text are found
in the *same window*, which is what keeps it from clicking unrelated Retry
buttons. Each scan visits every exposed Codex window and presses every matching
Retry button, so simultaneous conversations can be handled together.

The default button list includes the Chinese labels `重试` and `再试一次`. The
capacity error text is still matched by `at capacity`; use `--trigger` if the
error message is localized in your Codex build.

## Limitations

- macOS only, and specific to Codex Desktop's UI. If OpenAI restructures that
  error view, the label matching may need updating — `--button` and
  `--trigger` exist so you can adapt without recompiling.
- Depends on Electron exposing its web accessibility tree. It does today
  (verified: `AXButton :: Retry` is reachable and `AXPress` works), but that's
  not a contract.
- Ad-hoc signing means the rebuild/re-authorise cycle described above.
- Retrying does not create capacity. If the model is genuinely saturated, this
  will keep pressing a button that keeps failing; switching models is still the
  real fix. Use `--max-consecutive N` if you want it to give up and tell you.

Tested on macOS 26.5.1 (arm64), Swift 6.3.2, Codex Desktop 26.901.51231.

## License

MIT — see [LICENSE](LICENSE).
