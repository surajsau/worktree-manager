import AppKit
import SwiftUI

@main
enum Entry {
    static func main() async {
        // Debug/verification hook: print the worktree list and exit, no UI.
        if CommandLine.arguments.contains("--list") {
            for wt in await GitService.listWorktrees() {
                let flags = [
                    wt.dirty ? "dirty" : "clean",
                    wt.conflicts ? "CONFLICT" : nil,
                    wt.behind > 0 ? "↓\(wt.behind)" : nil,
                    wt.ahead > 0 ? "↑\(wt.ahead)" : nil,
                    wt.unpushed > 0 ? "\(wt.unpushed) unpushed" : nil,
                ].compactMap { $0 }.joined(separator: ", ")
                print("\(wt.branch)  [\(flags)]  \(wt.path)")
            }
            return
        }
        // Debug/verification hook: open a cmux tab for a path and exit, no UI.
        if let i = CommandLine.arguments.firstIndex(of: "--open-cmux"),
           i + 1 < CommandLine.arguments.count {
            let outcome = await GitService.openInCmux(path: CommandLine.arguments[i + 1])
            print(outcome.ok ? "ok" : "error: \(outcome.message ?? "failed")")
            return
        }
        WorktreeManagerApp.main()
    }
}

struct WorktreeManagerApp: App {
    @StateObject private var store = Store()

    init() {
        // Menu bar app: no Dock icon even when launched outside the bundle
        // (Info.plist's LSUIElement covers the bundled case).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Worktrees", systemImage: "tree") {
            MenuView()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
