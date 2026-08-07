import AppKit
import ServiceManagement
import SwiftUI

// UserDefaults keys shared between the settings window and the views that
// consume them (via @AppStorage, so changes apply live).
enum SettingsKeys {
    static let repoPath = "repo.path"
    static let worktreeDir = "repo.worktreeDir"
    static let branchPrefix = "repo.branchPrefix"
    static let mainBranch = "repo.mainBranch"
    static let terminalApp = "terminalApp"
    static let editorApp = "editorApp"
    static let featurePullLatest = "feature.pullLatest"
    static let featureBranchFrom = "feature.branchFrom"
    static let featureCopyPath = "feature.copyPath"
    static let featureOpenInTerminal = "feature.openInTerminal"
    static let featureOpenInEditor = "feature.openInEditor"
    static let featureAddExisting = "feature.addExisting"
    static let featureResolveConflicts = "feature.resolveConflicts"
    static let pollPullRequests = "pr.poll"
}

// An app a worktree can be handed to, picked from the ones actually installed.
// Bundle IDs rather than names alone, so the app's own icon can be drawn on the
// row button (SF Symbols has no glyph for any of these).
protocol ExternalApps {
    static var known: [(name: String, bundleID: String)] { get }
    static var fallback: String { get }
    static var settingsKey: String { get }
}

extension ExternalApps {
    static func installed() -> [String] {
        known.compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
                ? $0.name : nil
        }
    }

    // The stored choice, or — on a machine that has never opened Settings —
    // whichever known app is installed.
    static var selected: String {
        if let stored = UserDefaults.standard.string(forKey: settingsKey), !stored.isEmpty {
            return stored
        }
        return installed().first ?? fallback
    }

    static func bundleID(named name: String) -> String? {
        known.first { $0.name == name }?.bundleID
    }
}

enum TerminalApps: ExternalApps {
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
    static let fallback = "Terminal"
    static let settingsKey = SettingsKeys.terminalApp
}

enum EditorApps: ExternalApps {
    // One entry per bundle ID rather than per product: a JetBrains or Studio
    // preview channel is a separate app with its own ID, and only the ones
    // actually installed reach the picker.
    static let known: [(name: String, bundleID: String)] = [
        ("Android Studio", "com.google.android.studio"),
        ("Android Studio Preview", "com.google.android.studio.preview"),
        ("Android Studio EAP", "com.google.android.studio-EAP"),
        ("Xcode", "com.apple.dt.Xcode"),
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("IntelliJ IDEA", "com.jetbrains.intellij"),
        ("IntelliJ IDEA CE", "com.jetbrains.intellij.ce"),
        ("Zed", "dev.zed.Zed"),
        ("Sublime Text", "com.sublimetext.4"),
        ("Nova", "com.panic.Nova"),
        ("Finder", "com.apple.finder"),
    ]
    // Finder is on every Mac, so "open the worktree" always does something.
    static let fallback = "Finder"
    static let settingsKey = SettingsKeys.editorApp
}

struct SettingsView: View {
    @AppStorage(SettingsKeys.repoPath) private var repoPath = ""
    @AppStorage(SettingsKeys.worktreeDir) private var worktreeDir = ""
    @AppStorage(SettingsKeys.branchPrefix) private var branchPrefix = ""
    @AppStorage(SettingsKeys.mainBranch) private var mainBranch = ""
    @AppStorage(SettingsKeys.terminalApp) private var terminalApp = TerminalApps.selected
    @AppStorage(SettingsKeys.editorApp) private var editorApp = EditorApps.selected
    @AppStorage(SettingsKeys.featurePullLatest) private var pullLatest = true
    @AppStorage(SettingsKeys.featureBranchFrom) private var branchFrom = true
    @AppStorage(SettingsKeys.featureCopyPath) private var copyPath = true
    @AppStorage(SettingsKeys.featureOpenInTerminal) private var openInTerminal = true
    @AppStorage(SettingsKeys.featureOpenInEditor) private var openInEditor = true
    @AppStorage(SettingsKeys.featureAddExisting) private var addExisting = true
    @AppStorage(SettingsKeys.featureResolveConflicts) private var resolveConflicts = true
    @AppStorage(SettingsKeys.pollPullRequests) private var pollPRs = true

    // Detected once per window; each list has an always-present fallback.
    private let installedTerminals = TerminalApps.installed()
    private let installedEditors = EditorApps.installed()

    // Keep the stored value selectable even if that app is gone, otherwise the
    // Picker has a selection with no matching tag.
    private func choices(_ installed: [String], selected: String) -> [String] {
        installed.contains(selected) ? installed : installed + [selected]
    }

    var body: some View {
        Form {
            Section {
                PathRow(label: "Repository", path: $repoPath, prompt: "/path/to/your/repo")
                PathRow(label: "Worktree folder", path: $worktreeDir,
                        prompt: Config.defaultWorktreeDir)
                TextField("Main branch", text: $mainBranch, prompt: Text("main"))
                TextField("Branch prefix", text: $branchPrefix, prompt: Text("none"))
            } header: {
                Text("Repository")
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    if !repoPath.isEmpty && !Self.isGitRepo(repoPath) {
                        Label("That folder isn’t a git repository.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text("Worktrees are created in the worktree folder, one per branch. "
                         + "Leave it empty for \(Config.defaultWorktreeDir).")
                    Text("Main branch is the trunk stacks sit on: `origin/\(Config.mainBranch)` "
                         + "is what new branches start from, what merged branches are measured "
                         + "against, and what Pull merges in.")
                    Text(branchPrefix.isEmpty
                         ? "With no branch prefix, a new worktree named `fix-crash` becomes branch `fix-crash`."
                         : "A new worktree named `fix-crash` becomes branch `\(branchPrefix)fix-crash`.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Apps") {
                Picker("Terminal", selection: $terminalApp) {
                    ForEach(choices(installedTerminals, selected: terminalApp), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .pickerStyle(.menu)
                Picker("Editor", selection: $editorApp) {
                    ForEach(choices(installedEditors, selected: editorApp), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .pickerStyle(.menu)
            }
            Section {
                Toggle("Pull latest \(Config.trunkRef)", isOn: $pullLatest)
                Toggle("New worktree from branch", isOn: $branchFrom)
                Toggle("Copy worktree path", isOn: $copyPath)
                Toggle("Open in Terminal", isOn: $openInTerminal)
                Toggle("Open in \(editorApp)", isOn: $openInEditor)
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
        // Fixed height, not fixedSize(): with the repository fields on top of
        // the feature list and the legend, the ideal height is taller than a
        // laptop screen. The form scrolls inside this.
        .frame(width: 440, height: 640)
        // The shell scripts read the same settings from a config file, and are
        // run outside the app often enough that it has to stay current.
        .onChange(of: repoPath) { Config.writeShellConfig() }
        .onChange(of: worktreeDir) { Config.writeShellConfig() }
        .onChange(of: branchPrefix) { Config.writeShellConfig() }
        .onChange(of: mainBranch) { Config.writeShellConfig() }
    }

    private static func isGitRepo(_ path: String) -> Bool {
        // A worktree's .git is a file, not a directory, so existence is the test.
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }
}

// A path field with the folder picker next to it — typing a path works, but
// nobody should have to.
private struct PathRow: View {
    let label: String
    @Binding var path: String
    let prompt: String

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(label, text: $path, prompt: Text(prompt))
                    .labelsHidden()
                    .truncationMode(.head)
                Button("Choose…") { choose() }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path)
        }
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
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
