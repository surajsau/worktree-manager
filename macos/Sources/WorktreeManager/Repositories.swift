import SwiftUI

// The seam between the UI and the outside world. Everything below Store that
// touches git, GitHub, the disk or another app goes through one of these, so
// the whole panel can be driven from fake data with no repo and no network —
// see Testing/Fakes.swift and `--test`.
//
// The protocols are deliberately shaped like what Store calls, not like what
// git can do: a wider surface would be more to fake and no more useful.

protocol WorktreeRepository: Sendable {
    func listWorktrees() async -> [Worktree]
    func listBaseBranches() async -> [String]
    func fetchTrunk() async
    func createWorktree(name: String, base: String?) async -> OpOutcome
    func addExistingWorktree(branch: String) async -> OpOutcome
    func deleteWorktree(path: String, branch: String) async -> OpOutcome
    func pullLatest(path: String) async -> OpOutcome
    func open(path: String, app: String) async -> OpOutcome
    func openInCmux(path: String) async -> OpOutcome
    func resolveConflicts(path: String, command: String) async -> OpOutcome
    var cmuxAvailable: Bool { get }
}

protocol PullRequestRepository: Sendable {
    func fetchPullRequests() async -> Result<[PullRequest], GitHubService.Failure>
}

// The on-disk PR snapshot, so the first menu open of the day already has PR
// numbers on the rows.
protocol PRSnapshotStore: Sendable {
    func load() -> PRSnapshot?
    func save(_ snapshot: PRSnapshot)
}

@MainActor
protocol AvatarLoading {
    func load(_ url: String)
}

// MARK: - Live implementations

struct LiveWorktreeRepository: WorktreeRepository {
    func listWorktrees() async -> [Worktree] { await GitService.listWorktrees() }
    func listBaseBranches() async -> [String] { await GitService.listBaseBranches() }
    func fetchTrunk() async { await GitService.fetchTrunk() }

    func createWorktree(name: String, base: String?) async -> OpOutcome {
        await GitService.createWorktree(name: name, base: base)
    }

    func addExistingWorktree(branch: String) async -> OpOutcome {
        await GitService.addExistingWorktree(branch: branch)
    }

    func deleteWorktree(path: String, branch: String) async -> OpOutcome {
        await GitService.deleteWorktree(path: path, branch: branch)
    }

    func pullLatest(path: String) async -> OpOutcome { await GitService.pullLatest(path: path) }
    func open(path: String, app: String) async -> OpOutcome { await GitService.open(path: path, app: app) }
    func openInCmux(path: String) async -> OpOutcome { await GitService.openInCmux(path: path) }

    func resolveConflicts(path: String, command: String) async -> OpOutcome {
        await GitService.resolveConflicts(path: path, command: command)
    }

    var cmuxAvailable: Bool { GitService.cmuxAvailable }
}

struct LivePullRequestRepository: PullRequestRepository {
    func fetchPullRequests() async -> Result<[PullRequest], GitHubService.Failure> {
        await GitHubService.fetchPullRequests()
    }
}

struct DiskPRSnapshotStore: PRSnapshotStore {
    func load() -> PRSnapshot? { PRCache.load() }
    func save(_ snapshot: PRSnapshot) { PRCache.save(snapshot) }
}

extension AvatarCache: AvatarLoading {}

// MARK: - Environment

// Whether the cmux CLI is installed decides if a conflicted row offers the
// Resolve chip. Through the environment rather than read from GitService in the
// view, so a render test gets the same row on any machine.
private struct CmuxAvailableKey: EnvironmentKey {
    static let defaultValue = GitService.cmuxAvailable
}

extension EnvironmentValues {
    var cmuxAvailable: Bool {
        get { self[CmuxAvailableKey.self] }
        set { self[CmuxAvailableKey.self] = newValue }
    }
}
