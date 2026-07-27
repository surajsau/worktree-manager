import AppKit
import ServiceManagement
import SwiftUI

// UserDefaults keys shared between the settings window and the views that
// consume them (via @AppStorage, so changes apply live).
enum SettingsKeys {
    static let terminalApp = "terminalApp"
    static let featurePullLatest = "feature.pullLatest"
    static let featureBranchFrom = "feature.branchFrom"
    static let featureCopyPath = "feature.copyPath"
    static let featureOpenInTerminal = "feature.openInTerminal"
    static let featureOpenInStudio = "feature.openInStudio"
    static let featureAddExisting = "feature.addExisting"
}

enum TerminalApps {
    // cmux is special-cased: opening goes through GitService.openInCmux
    // (focus-or-create tab via its CLI) instead of a plain `open -a`.
    static let cmuxName = "cmux"

    static let known: [(name: String, bundleID: String)] = [
        ("Terminal", "com.apple.Terminal"),
        (cmuxName, Config.cmuxBundleID),
        ("iTerm", "com.googlecode.iterm2"),
        ("Warp", "dev.warp.Warp-Stable"),
        ("Ghostty", "com.mitchellh.ghostty"),
        ("Alacritty", "org.alacritty"),
        ("kitty", "net.kovidgoyal.kitty"),
        ("WezTerm", "com.github.wez.wezterm"),
    ]

    static func installed() -> [String] {
        known.compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
                ? $0.name : nil
        }
    }

    static var selected: String {
        UserDefaults.standard.string(forKey: SettingsKeys.terminalApp) ?? "Terminal"
    }
}

struct SettingsView: View {
    @AppStorage(SettingsKeys.terminalApp) private var terminalApp = "Terminal"
    @AppStorage(SettingsKeys.featurePullLatest) private var pullLatest = true
    @AppStorage(SettingsKeys.featureBranchFrom) private var branchFrom = true
    @AppStorage(SettingsKeys.featureCopyPath) private var copyPath = true
    @AppStorage(SettingsKeys.featureOpenInTerminal) private var openInTerminal = true
    @AppStorage(SettingsKeys.featureOpenInStudio) private var openInStudio = true
    @AppStorage(SettingsKeys.featureAddExisting) private var addExisting = true

    // Detected once per window; Terminal.app always exists as a fallback.
    private let installedTerminals = TerminalApps.installed()

    private var terminalChoices: [String] {
        // Keep the stored value selectable even if that app is gone,
        // otherwise the Picker has a selection with no matching tag.
        installedTerminals.contains(terminalApp)
            ? installedTerminals
            : installedTerminals + [terminalApp]
    }

    var body: some View {
        Form {
            Section("Terminal") {
                Picker("Default terminal app", selection: $terminalApp) {
                    ForEach(terminalChoices, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Section {
                Toggle("Pull latest origin/main", isOn: $pullLatest)
                Toggle("New worktree from branch", isOn: $branchFrom)
                Toggle("Copy worktree path", isOn: $copyPath)
                Toggle("Open in Terminal", isOn: $openInTerminal)
                Toggle("Open in Android Studio", isOn: $openInStudio)
                Toggle("Add existing branch", isOn: $addExisting)
            } header: {
                Text("Features")
            } footer: {
                Text("Disabled features are hidden from the worktree list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("General") {
                LoginItemToggle()
                Button("Quit Worktree Manager") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize()
    }
}

struct LoginItemToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Start at Login", isOn: Binding(
            get: { enabled },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    enabled = newValue
                } catch {
                    // Registration only works from a proper .app bundle;
                    // leave the toggle unchanged on failure.
                    enabled = SMAppService.mainApp.status == .enabled
                }
            }
        ))
    }
}
