// Entry point: parses arguments, then either dumps the tree, runs headless,
// or launches the menu bar app.

import Foundation
import ApplicationServices
import AppKit

var config = Watcher.Config()
var dumpMode = false
var dumpAll = false
var headless = false
var dumpOut: String?

var arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    let arg = arguments[index]
    func next() -> String? {
        index += 1
        return index < arguments.count ? arguments[index] : nil
    }
    switch arg {
    case "--dump":      dumpMode = true
    case "--dump-all":  dumpMode = true; dumpAll = true
    case "--headless":  headless = true
    case "--out":       dumpOut = next()
    case "--dry-run":   config.dryRun = true
    case "--any-retry": config.triggers = []
    case "--interval":  config.interval = Double(next() ?? "") ?? config.interval
    case "--cooldown":  config.cooldown = Double(next() ?? "") ?? config.cooldown
    case "--max-consecutive": config.maxConsecutive = Int(next() ?? "") ?? config.maxConsecutive
    case "--trigger":   config.triggers = [next() ?? "at capacity"]
    case "--button":
        config.buttonLabels = (next() ?? "retry,try again,重试,再试一次").lowercased()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    case "-h", "--help":
        print("""
        codex-retry-watcher — auto-press Codex Desktop's Retry button

          (no flags)          run as a menu bar app
          --headless          run with no UI (logs only)
          --dump              print Retry/trigger-related accessibility nodes and exit
                              (NOTE: run from a terminal this reports the TERMINAL's
                               accessibility permission, not the app's — use the
                               menu's "导出无障碍树" item to test the app itself)
          --dump-all          print the whole accessibility tree and exit
          --out <path>        with --dump, write to a file instead of stdout
          --dry-run           log what would be pressed, without pressing
          --interval <sec>    scan interval (default 3)
          --cooldown <sec>    wait after a press (default 10)
          --max-consecutive N give up after N presses without recovery
                              (default 0 = never give up, retry while the error shows)
          --trigger <text>    require this text in the window (default "at capacity")
          --any-retry         press Retry regardless of the message shown
          --button <a,b>      button labels to press (default "retry,try again,重试,再试一次")

        log: ~/.local/share/codex-retry-watcher/watcher.log
        """)
        exit(0)
    default:
        FileHandle.standardError.write("unknown argument: \(arg)\n".data(using: .utf8)!)
        exit(2)
    }
    index += 1
}

if dumpMode {
    let result = accessibilityDump(all: dumpAll, config: config)
    if let path = dumpOut {
        do {
            try result.text.write(toFile: path, atomically: true, encoding: .utf8)
            print("wrote \(path)")
        } catch {
            FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    } else {
        print(result.text)
    }
    exit(result.ok ? 0 : 1)
}

if headless {
    if !AXIsProcessTrusted() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        logLine("no accessibility permission yet — grant it in System Settings › Privacy & Security › Accessibility")
    }
    let watcher = Watcher(config: config)
    logLine("headless watcher started")
    watcher.start()
    RunLoop.main.run()
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate(config: config)
    application.delegate = delegate
    // .accessory: menu bar only, no Dock icon, no app switcher entry.
    application.setActivationPolicy(.accessory)
    application.run()
}
