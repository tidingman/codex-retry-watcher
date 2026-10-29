// Scanning/pressing engine. Runs off the main thread so a slow accessibility
// walk can never stall the menu bar.

import Foundation
import ApplicationServices
import AppKit

// MARK: - logging

let logDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/share/codex-retry-watcher", isDirectory: true)
let logFileURL = logDirectory.appendingPathComponent("watcher.log")

let timeOfDayFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
}()

private let logStampFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
}()

private let logQueue = DispatchQueue(label: "codex-retry-watcher.log")

func logLine(_ message: String) {
    let line = "[\(logStampFormatter.string(from: Date()))] \(message)\n"
    print(line, terminator: "")
    fflush(stdout)

    logQueue.async {
        let fm = FileManager.default
        try? fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        if let attrs = try? fm.attributesOfItem(atPath: logFileURL.path),
           let size = attrs[.size] as? Int, size > 2_000_000 {
            try? fm.removeItem(at: logFileURL)   // keep the log bounded
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            fm.createFile(atPath: logFileURL.path, contents: data)
        }
    }
}

func notify(_ title: String, _ body: String) {
    func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", "display notification \(quoted(body)) with title \(quoted(title))"]
    try? process.run()
}

// MARK: - watcher

final class Watcher {

    struct Config {
        var triggers: [String] = ["at capacity"]
        var buttonLabels: [String] = ["retry", "try again", "重试", "再试一次"]
        var interval: TimeInterval = 3
        var cooldown: TimeInterval = 10
        /// 0 means unlimited: keep retrying as long as the error is on screen.
        var maxConsecutive = 0
        var dryRun = false
    }

    struct Status {
        var enabled = true
        var dryRun = false
        var permitted = false
        var codexRunning = false
        var errorVisible = false
        var gaveUp = false
        var consecutive = 0
        var totalPresses = 0
        var lastPress: Date?
        var lastScan: Date?
    }

    /// Immutable after init except for `dryRun`, which lives in `Status`.
    let config: Config

    /// Called on the main thread after every state change.
    var onStatus: ((Status) -> Void)?

    private let lock = NSLock()
    private var state = Status()
    private let queue = DispatchQueue(label: "codex-retry-watcher.scan")
    private var timer: DispatchSourceTimer?
    /// Only touched on `queue`.
    private var loggedPermission: Bool?

    init(config: Config) {
        self.config = config
        state.dryRun = config.dryRun
    }

    var status: Status {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    private func mutate(_ change: (inout Status) -> Void) {
        lock.lock()
        change(&state)
        let snapshot = state
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStatus?(snapshot) }
    }

    // MARK: control

    func start() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.5, repeating: config.interval, leeway: .milliseconds(500))
        source.setEventHandler { [weak self] in self?.scan(force: false) }
        timer = source
        source.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func setEnabled(_ value: Bool) {
        mutate { s in
            s.enabled = value
            if value { s.gaveUp = false; s.consecutive = 0 }
        }
        logLine(value ? "auto-retry enabled" : "auto-retry paused")
    }

    func setDryRun(_ value: Bool) {
        mutate { $0.dryRun = value }
        logLine(value ? "dry-run on" : "dry-run off")
    }

    /// Press Retry once regardless of trigger text, cooldown or give-up state.
    func retryNow() {
        queue.async { [weak self] in self?.scan(force: true) }
    }

    // MARK: scanning

    private func scan(force: Bool) {
        let permitted = AXIsProcessTrusted()

        if loggedPermission != permitted {
            loggedPermission = permitted
            logLine(permitted
                ? "accessibility permission OK"
                : "accessibility permission MISSING — cannot read buttons (re-grant in System Settings › Privacy & Security › Accessibility)")
        }

        let runningApp = codexAppElement()
        guard permitted, let (app, _) = runningApp else {
            mutate { s in
                s.permitted = permitted
                s.codexRunning = runningApp != nil
                s.errorVisible = false
                s.lastScan = Date()
            }
            return
        }

        var errorVisible = false
        var pressed = false
        var giveUpNow = false
        var pressLog: [String] = []
        let scanStatus = status
        // A cooldown belongs to a scan cycle, not to the first window we
        // happen to visit. Otherwise the first matching window suppresses
        // every other conversation until the next timer tick.
        let cooldownActive = !force && scanStatus.lastPress.map {
            Date().timeIntervalSince($0) < config.cooldown
        } ?? false

        for (windowIndex, window) in axElements(app, "AXWindows").enumerated() {
            var sawTrigger = false
            var buttons: [AXUIElement] = []

            axWalk(window) { node in
                if !sawTrigger, textContainsAny(node.text, needles: config.triggers) { sawTrigger = true }
                if isButtonRole(node.role),
                   textMatchesLabel(node.text, labels: config.buttonLabels) {
                    buttons.append(node.el)
                }
                return false
            }

            // With no trigger configured, a visible Retry button *is* the signal.
            if sawTrigger || (config.triggers.isEmpty && !buttons.isEmpty) { errorVisible = true }

            let allowed = sawTrigger || config.triggers.isEmpty || force
            guard allowed, !buttons.isEmpty else { continue }

            if !force {
                guard scanStatus.enabled, !scanStatus.gaveUp, !cooldownActive else { continue }
                if config.maxConsecutive > 0, scanStatus.consecutive >= config.maxConsecutive {
                    giveUpNow = true
                    continue
                }
            }

            for target in buttons {
                let label = axString(target, "AXTitle") ?? axString(target, "AXDescription") ?? "Retry"

                if scanStatus.dryRun {
                    pressLog.append("[dry-run] would press \"\(label)\" in window \(windowIndex)\(force ? " (manual)" : "")")
                } else {
                    let err = AXUIElementPerformAction(target, "AXPress" as CFString)
                    guard err == .success else {
                        pressLog.append("press failed on \"\(label)\" in window \(windowIndex): AXError \(err.rawValue)")
                        continue
                    }
                    pressLog.append("pressed \"\(label)\" in window \(windowIndex)\(force ? " (manual)" : "")")
                }
                pressed = true
                mutate { s in
                    s.lastPress = Date()
                    s.totalPresses += 1
                }
            }
        }

        let before = status
        let cleared = !errorVisible && !pressed
        let shouldLogReset = cleared && (before.consecutive > 0 || before.gaveUp)

        mutate { s in
            s.permitted = true
            s.codexRunning = true
            s.errorVisible = errorVisible
            s.lastScan = Date()
            if giveUpNow { s.gaveUp = true }
            if pressed && !force { s.consecutive += 1 }
            if cleared { s.consecutive = 0; s.gaveUp = false }
        }

        for line in pressLog { logLine(line) }
        if giveUpNow, !before.gaveUp {
            logLine("gave up after \(before.consecutive) presses without recovery")
            notify("Codex 重试守护", "连续 \(before.consecutive) 次重试仍未恢复,请手动重试或切换模型")
        }
        if shouldLogReset { logLine("error cleared — retry budget reset") }
    }
}
