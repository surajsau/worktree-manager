import Foundation
@testable import WorktreeManager

// In-memory stand-ins for the repository protocols. They record what was asked
// of them, so a test can assert that pressing Delete actually deleted — and
// they mutate their own state, so the refresh that follows sees the result.
//
// A class with a lock rather than an actor: the protocols are non-isolated, and
// tests want to read the recorded calls synchronously.
final class FakeWorktreeRepository: WorktreeRepository, @unchecked Sendable {
    enum Call: Equatable {
        case list
        case listBaseBranches
        case fetchTrunk
        case create(name: String, base: String?)
        case addExisting(branch: String)
        case delete(path: String, branch: String)
        case pull(path: String)
        case open(path: String, app: String)
        case openInCmux(path: String)
        case resolveConflicts(path: String, command: String)
    }

    private let lock = NSLock()
    private var _worktrees: [Worktree]
    private var _calls: [Call] = []

    var baseBranches: [String] = ["origin/main", "origin/minor"]
    var cmuxAvailable = true
    // Scripted result for the next mutating call; nil means "succeed".
    var nextOutcome: OpOutcome?
    // Called with the path just before deleteWorktree returns — lets a test
    // observe the busy state the UI shows while the work is in flight.
    var onDelete: (@Sendable (String) -> Void)?

    init(_ worktrees: [Worktree] = []) {
        _worktrees = worktrees
    }

    var calls: [Call] {
        lock.sync { _calls }
    }

    var worktrees: [Worktree] {
        get { lock.sync { _worktrees } }
        set { lock.sync { _worktrees = newValue } }
    }

    func callCount(_ predicate: (Call) -> Bool) -> Int {
        calls.filter(predicate).count
    }

    private func record(_ call: Call) {
        lock.sync { _calls.append(call) }
    }

    private func outcome() -> OpOutcome {
        nextOutcome ?? OpOutcome(ok: true)
    }

    func listWorktrees() async -> [Worktree] {
        record(.list)
        return worktrees
    }

    func listBaseBranches() async -> [String] {
        record(.listBaseBranches)
        return baseBranches
    }

    func fetchTrunk() async {
        record(.fetchTrunk)
    }

    func createWorktree(name: String, base: String?) async -> OpOutcome {
        record(.create(name: name, base: base))
        let result = outcome()
        if result.ok {
            worktrees.append(SampleData.worktree(Config.branchPrefix + name))
        }
        return result
    }

    func addExistingWorktree(branch: String) async -> OpOutcome {
        record(.addExisting(branch: branch))
        let result = outcome()
        if result.ok { worktrees.append(SampleData.worktree(branch)) }
        return result
    }

    func deleteWorktree(path: String, branch: String) async -> OpOutcome {
        record(.delete(path: path, branch: branch))
        onDelete?(path)
        let result = outcome()
        if result.ok { worktrees.removeAll { $0.path == path } }
        return result
    }

    func pullLatest(path: String) async -> OpOutcome {
        record(.pull(path: path))
        return outcome()
    }

    func open(path: String, app: String) async -> OpOutcome {
        record(.open(path: path, app: app))
        return outcome()
    }

    func openInCmux(path: String) async -> OpOutcome {
        record(.openInCmux(path: path))
        return outcome()
    }

    func resolveConflicts(path: String, command: String) async -> OpOutcome {
        record(.resolveConflicts(path: path, command: command))
        return outcome()
    }
}

final class FakePullRequestRepository: PullRequestRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var _fetches = 0
    private var _result: Result<[PullRequest], GitHubService.Failure>

    init(_ pullRequests: [PullRequest] = []) {
        _result = .success(pullRequests)
    }

    var fetches: Int { lock.sync { _fetches } }

    var result: Result<[PullRequest], GitHubService.Failure> {
        get { lock.sync { _result } }
        set { lock.sync { _result = newValue } }
    }

    func fail(_ message: String) {
        result = .failure(GitHubService.Failure(message: message))
    }

    func fetchPullRequests() async -> Result<[PullRequest], GitHubService.Failure> {
        lock.sync { _fetches += 1 }
        return result
    }
}

final class InMemoryPRSnapshotStore: PRSnapshotStore, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: PRSnapshot?
    private var _saves = 0

    init(_ snapshot: PRSnapshot? = nil) {
        self.snapshot = snapshot
    }

    var saves: Int { lock.sync { _saves } }
    var stored: PRSnapshot? { lock.sync { snapshot } }

    func load() -> PRSnapshot? { lock.sync { snapshot } }

    func save(_ snapshot: PRSnapshot) {
        lock.sync {
            self.snapshot = snapshot
            _saves += 1
        }
    }
}

@MainActor
final class RecordingAvatarLoader: AvatarLoading {
    private(set) var requested: [String] = []

    func load(_ url: String) {
        requested.append(url)
    }
}

extension NSLock {
    // Foundation has withLock on NSLocking, but its closure is @Sendable;
    // these fakes just need a plain critical section.
    func sync<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
