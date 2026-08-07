import Foundation

// Which repository the app manages is a setting, not a constant: one build
// serves any checkout. The values live in UserDefaults (written by the Settings
// window) and are mirrored into a shell config file so the scripts — which can
// also be run straight from a terminal — see exactly what the app sees.
enum Config {

    // MARK: - Repository (set in Settings)

    // Empty until Settings names a repository; the panel says so rather than
    // running git against nothing.
    static var mainRepo: String { setting(SettingsKeys.repoPath, env: "WORKTREE_MANAGER_REPO") ?? "" }
    static var isConfigured: Bool { !mainRepo.isEmpty }

    static var worktreeDir: String {
        setting(SettingsKeys.worktreeDir, env: "WORKTREE_MANAGER_WORKTREE_DIR") ?? defaultWorktreeDir
    }

    // A sibling of the checkout, which is where a repo's worktrees usually go —
    // inside it they would show up as untracked files.
    static var defaultWorktreeDir: String {
        mainRepo.isEmpty
            ? NSHomeDirectory() + "/worktrees"
            : (mainRepo as NSString).deletingLastPathComponent + "/worktrees"
    }

    // Put in front of every branch the create flow makes (e.g. "alex/"). Empty
    // is a real choice, so an exported empty prefix counts as one.
    static var branchPrefix: String {
        ProcessInfo.processInfo.environment["WORKTREE_MANAGER_BRANCH_PREFIX"]
            ?? UserDefaults.standard.string(forKey: SettingsKeys.branchPrefix)
            ?? ""
    }

    static var mainBranch: String {
        setting(SettingsKeys.mainBranch, env: "WORKTREE_MANAGER_MAIN_BRANCH") ?? "main"
    }

    // The ref every stack is measured against: a branch with no commits outside
    // it is fully merged, and stack roots are the branches that sit directly on
    // it. Kept separate from defaultBase so the two can diverge later.
    static var trunkRef: String { "origin/" + mainBranch }
    static var defaultBase: String { trunkRef }

    // The environment wins over the stored setting, which is what makes the
    // debug hooks (`--list`, `--stacks`) usable from a plain `swift run`: run
    // outside the .app bundle, UserDefaults is a different domain and has none
    // of the app's settings in it.
    private static func setting(_ key: String, env: String) -> String? {
        nonEmpty(ProcessInfo.processInfo.environment[env])
            ?? nonEmpty(UserDefaults.standard.string(forKey: key))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    // MARK: - Fixed

    static let prPollInterval: TimeInterval = 30 * 60
    // gh is not on a login item's PATH, so it is resolved by absolute path.
    static let ghCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    static var ghPath: String? {
        ghCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var cacheDir: String {
        NSHomeDirectory() + "/Library/Caches/WorktreeManager"
    }
    static let cmuxBundleID = "com.cmuxterm.app"
    // Typed into a fresh cmux workspace at the conflicted worktree. cmux runs it
    // through an interactive login shell, so shell aliases (`opus`) resolve.
    static let resolveConflictsCommand = "opus /resolve-conflicts"
    // Agent-system artifacts: the local-markdown issue tracker and ship-skill
    // runs. Rows surface these; delete never touches them. The tracker path is
    // per-repo, and mirrors what agent-artifacts.sh derives.
    static var trackerScratchDir: String {
        let repo = (mainRepo as NSString).lastPathComponent
        return repo.isEmpty ? "" : NSHomeDirectory() + "/tmp/\(repo)-agents/scratch"
    }
    static let shipRunsDir = NSHomeDirectory() + "/tmp/ship"

    // MARK: - Shell scripts

    // The create/add logic lives in standalone shell scripts (usable from a
    // terminal or a Claude skill) — the app shells out to them. build-app.sh
    // copies them into the bundle; a `swift run` from the checkout finds them
    // next to the package instead.
    static var scriptsDir: String {
        if let dir = ProcessInfo.processInfo.environment["WORKTREE_MANAGER_HOME"] { return dir }
        if let bundled = Bundle.main.resourcePath,
           FileManager.default.fileExists(atPath: bundled + "/create-worktree.sh") {
            return bundled
        }
        return FileManager.default.currentDirectoryPath
    }
    static var createScript: String { scriptsDir + "/create-worktree.sh" }
    static var addExistingScript: String { scriptsDir + "/add-existing-worktree.sh" }

    // What the scripts read when the app invokes them. Passed explicitly rather
    // than left to the config file, so a setting changed a second ago wins.
    static var shellEnvironment: [String: String] {
        [
            "WORKTREE_MANAGER_REPO": mainRepo,
            "WORKTREE_MANAGER_WORKTREE_DIR": worktreeDir,
            "WORKTREE_MANAGER_BRANCH_PREFIX": branchPrefix,
            "WORKTREE_MANAGER_MAIN_BRANCH": mainBranch,
        ]
    }

    static var shellConfigFile: String {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? NSHomeDirectory() + "/.config"
        return base + "/worktree-manager/config"
    }

    // Keeps the scripts usable on their own: run from a terminal they have no
    // app around to hand them the settings, so the settings are written here
    // every time they change.
    static func writeShellConfig() {
        let body = shellEnvironment.keys.sorted().map { key in
            "\(key)='\(shellEnvironment[key]!.replacingOccurrences(of: "'", with: "'\\''"))'"
        }.joined(separator: "\n")
        let contents = """
        # Written by Worktree Manager's Settings window — edit it there.
        # Sourced by create-worktree.sh, add-existing-worktree.sh and their
        # helpers; an exported variable of the same name wins over this file.
        \(body)

        """
        let url = URL(fileURLWithPath: shellConfigFile)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct Worktree: Identifiable, Equatable, Sendable {
    let branch: String
    let name: String
    let path: String
    let folder: String
    let dirty: Bool
    let dirtyCount: Int
    let conflicts: Bool
    let ahead: Int
    let behind: Int
    let unpushed: Int
    let ticketPath: String?
    let shipRunPath: String?
    // Commits on this branch that Config.trunkRef doesn't have.
    let commitsAboveTrunk: Int
    // Whether any commit ever landed on this branch, read from its reflog.
    // Zero commits above the trunk means one of two opposite things — the
    // branch merged, or it was just created and has no work yet — and the
    // commit graph can't tell them apart. This can.
    let hasOwnCommits: Bool
    // Commits the trunk has that this branch doesn't — i.e. what the row's
    // "Pull" button would bring in. Distinct from `behind`, measured against the
    // branch's own remote when one exists.
    let behindTrunk: Int
    let tip: String
    // The SHAs those commits have. A sibling branch whose tip is in here is an
    // ancestor of this one, which is how a parent is found for a branch with no
    // PR to name its base.
    let containedTips: Set<String>

    var id: String { path }
    var merged: Bool { commitsAboveTrunk == 0 && hasOwnCommits }
    // Created but not committed on yet. Sits on the trunk with nothing above it,
    // so it gets a stack of its own rather than being hidden as merged.
    var isFresh: Bool { commitsAboveTrunk == 0 && !hasOwnCommits }
}

// MARK: - GitHub

enum CIState: String, Codable, Sendable {
    case success, failure, pending, none

    // GraphQL StatusState -> the three states worth a distinct colour.
    init(rollup: String?) {
        switch rollup {
        case "SUCCESS": self = .success
        case "FAILURE", "ERROR": self = .failure
        case "PENDING", "EXPECTED": self = .pending
        default: self = .none
        }
    }
}

enum Mergeability: String, Codable, Sendable {
    case mergeable, conflicting, unknown

    // CONFLICTING is trustworthy; UNKNOWN just means GitHub hasn't finished the
    // background merge test yet, so it must not be shown as a conflict.
    init(raw: String?) {
        switch raw {
        case "MERGEABLE": self = .mergeable
        case "CONFLICTING": self = .conflicting
        default: self = .unknown
        }
    }
}

enum ReviewState: String, Codable, Sendable {
    case approved, changesRequested, reviewRequired, none

    init(raw: String?) {
        switch raw {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        case "REVIEW_REQUIRED": self = .reviewRequired
        default: self = .none
        }
    }
}

struct Commenter: Codable, Hashable, Sendable {
    let login: String
    let avatarURL: String
    let isBot: Bool
    // You, on your own PR. Your own comments shouldn't light up the indicator —
    // nothing there is waiting on you — but an unresolved thread you opened
    // still counts.
    var isViewer: Bool = false
    // Unresolved review threads this person/bot started, so the avatar row can
    // put whoever is actually waiting on a reply first.
    var unresolved: Int
    var comments: Int
}

struct PullRequest: Identifiable, Codable, Equatable, Sendable {
    let number: Int
    let title: String
    let url: String
    let headRef: String
    let baseRef: String
    let isDraft: Bool
    let mergeable: Mergeability
    let review: ReviewState
    let ci: CIState
    let unresolvedThreads: Int
    let additions: Int
    let deletions: Int
    let updatedAt: Date
    // Distinct comment authors, unresolved-thread starters first.
    let participants: [Commenter]

    var id: Int { number }
    var humanComments: Int {
        participants.filter { !$0.isBot }.reduce(0) { $0 + $1.comments }
    }
}

struct PRSnapshot: Codable, Sendable {
    var pullRequests: [PullRequest]
    var fetchedAt: Date
}

struct OpOutcome: Sendable {
    var ok: Bool
    var message: String? = nil
    var conflict: Bool = false
}

struct CommandResult: Sendable {
    let code: Int32
    let stdout: String
    let stderr: String
}
