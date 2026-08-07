import Foundation

enum Config {
    static let mainRepo = "/Users/s24270/Documents/Github/abema-androidtv"
    static let worktreeDir = "/Users/s24270/Documents/Github/worktrees"
    static let branchPrefix = "suraj/"
    static let defaultBase = "origin/main"
    // The ref every stack is measured against: a branch with no commits outside
    // it is fully merged, and stack roots are the branches that sit directly on
    // it. Kept separate from defaultBase so the two can diverge later.
    static let trunkRef = "origin/main"
    static let prPollInterval: TimeInterval = 30 * 60
    // gh is not on a login item's PATH, so it is resolved by absolute path.
    static let ghCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    static var ghPath: String? {
        ghCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var cacheDir: String {
        NSHomeDirectory() + "/Library/Caches/WorktreeManager"
    }
    // The create/add logic lives in standalone shell scripts (shared with the
    // web server and Claude skills) — the app shells out to them.
    static let scriptsDir = "/Users/s24270/Documents/Github/worktree-manager"
    static var createScript: String { scriptsDir + "/create-worktree.sh" }
    static var addExistingScript: String { scriptsDir + "/add-existing-worktree.sh" }
    static let studioApp = "Android Studio"
    static let cmuxBundleID = "com.cmuxterm.app"
    // Typed into a fresh cmux workspace at the conflicted worktree. cmux runs it
    // through an interactive login shell, so shell aliases (`opus`) resolve.
    static let resolveConflictsCommand = "opus /resolve-conflicts"
    // Agent-system artifacts: the local-markdown issue tracker and ship-skill
    // runs. Rows surface these; delete never touches them.
    static let trackerScratchDir = NSHomeDirectory() + "/tmp/abema-androidtv-agents/scratch"
    static let shipRunsDir = NSHomeDirectory() + "/tmp/ship"
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
    // Commits the trunk has that this branch doesn't — i.e. what "Pull main"
    // would bring in. Distinct from `behind`, which is measured against the
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
