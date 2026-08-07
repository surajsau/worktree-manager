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
    static let featureResolveConflicts = "feature.resolveConflicts"
    static let pollPullRequests = "pr.poll"
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
    @AppStorage(SettingsKeys.featureResolveConflicts) private var resolveConflicts = true
    @AppStorage(SettingsKeys.pollPullRequests) private var pollPRs = true

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
                Toggle("Resolve merge conflict in cmux", isOn: $resolveConflicts)
            } header: {
                Text("Features")
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Disabled features are hidden from the worktree list.")
                    if resolveConflicts {
                        Text("Rows whose PR conflicts with its base, or whose worktree has a merge half-done, get a `resolve` chip that opens a cmux tab there running `\(Config.resolveConflictsCommand)`."
                             + (GitService.cmuxAvailable ? "" : " cmux.app isn’t installed, so the chip stays hidden."))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Refresh PR data every 30 minutes", isOn: $pollPRs)
            } header: {
                Text("Pull Requests")
            } footer: {
                Text(pollPRs
                     ? "One `gh api graphql` query per refresh, covering every open PR. Turn this off to fetch only when you press Refresh."
                     : "PR data is fetched only when you press Refresh, or when the menu opens with data older than 30 minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                StackLegend()
            } header: {
                Text("Legend")
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

// The stack rows carry two independent colour axes — CI on the dot, local
// working-tree state on the branch name — which is only obvious once someone
// tells you. This is that telling.
struct StackLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            row {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Circle().fill(StackStyle.ciPending).frame(width: 8, height: 8)
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.2).frame(width: 8, height: 8)
            } text: {
                Text("Dot — CI only: passing, running, failing, no PR")
            }
            row {
                Text("branch").foregroundStyle(.primary)
                Text("branch").foregroundStyle(StackStyle.dirty)
                Text("branch").foregroundStyle(.red)
            } text: {
                Text("Branch name — clean, uncommitted changes, merge conflict in progress")
            }
            row {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } text: {
                Text("PR conflicts with its base branch")
            }
            row {
                ResolveConflictButton {}
                    .allowsHitTesting(false)
            } text: {
                Text("Hand the conflict to an agent in cmux — shown next to either conflict signal above")
            }
            row {
                Circle().fill(Color.secondary.opacity(0.4)).frame(width: 10, height: 10)
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.4)).frame(width: 10, height: 10)
                Text("2").font(Typo.metaEmphasis).foregroundStyle(StackStyle.attention)
            } text: {
                Text("Unresolved review threads, by author — round is a person, square is a bot")
            }
            row {
                Image(systemName: "bubble.left").foregroundStyle(.tertiary)
            } text: {
                Text("A comment from a human other than you, with nothing unresolved")
            }
            row {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Image(systemName: "xmark.seal.fill").foregroundStyle(StackStyle.attention)
            } text: {
                Text("Approved / changes requested")
            }
            row {
                Text("3●").foregroundStyle(StackStyle.dirty)
                Text("↑1").foregroundStyle(StackStyle.dirty)
            } text: {
                Text("Uncommitted changes / commits not pushed anywhere")
            }
            row {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
            } text: {
                Text("A branch that forked off the stack rather than continuing it")
            }
            row {
                Text("No worktree")
                    .font(Typo.meta)
                    .foregroundStyle(.tertiary)
            } text: {
                Text("A PR in the stack that isn't checked out here")
            }
        }
        .padding(.vertical, 2)
    }

    private func row<Icon: View, Label: View>(
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder text: () -> Label
    ) -> some View {
        HStack(alignment: .center, spacing: 6) {
            HStack(spacing: 3) { icon() }
                .font(.system(size: 10))
                .frame(width: 52, alignment: .leading)
            text()
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
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
