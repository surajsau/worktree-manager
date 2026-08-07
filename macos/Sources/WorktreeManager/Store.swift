import Foundation
import SwiftUI

@MainActor
final class Store: ObservableObject {
    struct Banner: Equatable {
        let text: String
        let isError: Bool
    }

    @Published var worktrees: [Worktree] = []
    @Published var isLoading = false
    @Published var hasLoadedOnce = false
    @Published var banner: Banner?
    @Published var busyPaths: Set<String> = []
    @Published var baseBranches: [String] = []
    @Published var isLoadingBranches = false

    @Published var pullRequests: [PullRequest] = []
    @Published var prFetchedAt: Date?
    @Published var isLoadingPRs = false
    @Published var prError: String?

    private var pollTask: Task<Void, Never>?

    private let git: WorktreeRepository
    private let github: PullRequestRepository
    private let cache: PRSnapshotStore
    private let avatars: AvatarLoading

    // Defaults are the live ones, so the app constructs `Store()` as before;
    // tests hand it fakes instead.
    init(
        git: WorktreeRepository = LiveWorktreeRepository(),
        github: PullRequestRepository = LivePullRequestRepository(),
        cache: PRSnapshotStore = DiskPRSnapshotStore(),
        // nil rather than AvatarCache.shared: a main-actor default argument is
        // evaluated in a nonisolated context.
        avatars: AvatarLoading? = nil
    ) {
        self.git = git
        self.github = github
        self.cache = cache
        self.avatars = avatars ?? AvatarCache.shared
        // Whatever the last fetch saw, so the first menu open already has PR
        // numbers on the rows instead of a bare git tree.
        if let snapshot = cache.load() {
            pullRequests = snapshot.pullRequests
            prFetchedAt = snapshot.fetchedAt
        }
        rebuildTree()
    }

    // MARK: - Derived tree

    // Rebuilt only when its inputs change: SwiftUI reads this many times per
    // layout pass, and building the tree walks every branch's commit set.
    @Published private(set) var stacks: [Stack] = []
    @Published private(set) var mergedWorktrees: [Worktree] = []

    // Used only by the --render debug hook, to draw a tree shape that the real
    // repo doesn't currently contain.
    func injectForRender(worktrees: [Worktree], pullRequests: [PullRequest]) {
        self.worktrees = worktrees
        self.pullRequests = pullRequests
        hasLoadedOnce = true
        rebuildTree()
    }

    private func rebuildTree() {
        let tree = StackBuilder.build(worktrees: worktrees, pullRequests: pullRequests)
        stacks = tree.stacks
        mergedWorktrees = tree.merged
    }

    // Branches that need you, not signals: a branch whose PR conflicts *and*
    // whose worktree has the merge half-done is one thing to go and fix, and
    // the badge claims to count items.
    var attentionCount: Int {
        var refs = Set<String>()
        for pr in pullRequests
        where pr.ci == .failure || pr.mergeable == .conflicting || pr.unresolvedThreads > 0 {
            refs.insert(pr.headRef)
        }
        for wt in worktrees where wt.conflicts {
            refs.insert(wt.branch)
        }
        return refs.count
    }

    // MARK: - Refresh

    // Git state only: local, ~0.5s, so it runs on every menu open.
    func refresh() async {
        if isLoading { return }
        isLoading = true
        worktrees = await git.listWorktrees()
        rebuildTree()
        isLoading = false
        hasLoadedOnce = true
    }

    // Called when the menu opens: git always, PR data only when the cache has
    // aged out, so reopening the menu inside the poll window costs nothing.
    func refreshOnOpen() async {
        await refresh()
        let age = prFetchedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if age > Config.prPollInterval {
            await refreshPullRequests()
        }
    }

    // The explicit refresh button: fetches the trunk too, so merged-branch
    // detection is measured against an up-to-date origin/main.
    func refreshEverything() async {
        await git.fetchTrunk()
        async let gitState: Void = refresh()
        async let prs: Void = refreshPullRequests()
        _ = await (gitState, prs)
    }

    func refreshPullRequests() async {
        if isLoadingPRs { return }
        isLoadingPRs = true
        switch await github.fetchPullRequests() {
        case .success(let prs):
            pullRequests = prs
            prFetchedAt = Date()
            prError = nil
            rebuildTree()
            cache.save(PRSnapshot(pullRequests: prs, fetchedAt: Date()))
            for url in prs.flatMap({ $0.participants.map(\.avatarURL) }) {
                avatars.load(url)
            }
        case .failure(let failure):
            // Keep the cached PRs on screen — stale numbers beat none.
            prError = failure.message
        }
        isLoadingPRs = false
    }

    // 30-minute poll. One GraphQL query per tick, so the cost is negligible
    // next to GitHub's hourly quota; the app is otherwise idle.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Config.prPollInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                // Re-read the setting each tick so turning the poll off in
                // Settings takes effect without a relaunch.
                guard Self.pollingEnabled else { continue }
                await self?.git.fetchTrunk()
                await self?.refreshPullRequests()
                await self?.refresh()
            }
        }
    }

    private static var pollingEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.pollPullRequests) as? Bool ?? true
    }

    // Reads local refs only (no fetch), so it is cheap enough to redo whenever
    // the create form opens. Previous values stay on screen while it reloads.
    func loadBaseBranches() async {
        if isLoadingBranches { return }
        isLoadingBranches = true
        baseBranches = await git.listBaseBranches()
        isLoadingBranches = false
    }

    func create(name: String, base: String?) async -> OpOutcome {
        let outcome = await git.createWorktree(name: name, base: base)
        if outcome.ok {
            banner = Banner(text: "Created \(Config.branchPrefix)\(name).", isError: false)
            await refresh()
        }
        return outcome
    }

    func addExisting(branch: String) async -> OpOutcome {
        let outcome = await git.addExistingWorktree(branch: branch)
        if outcome.ok {
            banner = Banner(text: "Added worktree for \(branch).", isError: false)
            await refresh()
        }
        return outcome
    }

    func delete(_ wt: Worktree) async {
        busyPaths.insert(wt.path)
        let outcome = await git.deleteWorktree(path: wt.path, branch: wt.branch)
        busyPaths.remove(wt.path)
        banner = Banner(text: outcome.message ?? (outcome.ok ? "Deleted." : "delete failed"), isError: !outcome.ok)
        await refresh()
    }

    // Bulk-removes the branches already contained in the trunk. Every one of
    // them is checked again here rather than trusted from the view's snapshot,
    // because it is a destructive batch.
    func pruneMerged(_ candidates: [Worktree]) async {
        let safe = candidates.filter { $0.merged && !$0.dirty && $0.unpushed == 0 }
        guard !safe.isEmpty else {
            banner = Banner(text: "Nothing to prune.", isError: false)
            return
        }
        for wt in safe { busyPaths.insert(wt.path) }
        var removed: [String] = []
        var failed: [String] = []
        for wt in safe {
            let outcome = await git.deleteWorktree(path: wt.path, branch: wt.branch)
            if outcome.ok { removed.append(wt.branch) } else { failed.append(wt.branch) }
            busyPaths.remove(wt.path)
        }
        let skipped = candidates.count - safe.count
        var parts: [String] = []
        if !removed.isEmpty { parts.append("Pruned \(removed.count) merged branch\(removed.count == 1 ? "" : "es").") }
        if skipped > 0 { parts.append("\(skipped) skipped (uncommitted or unpushed work).") }
        if !failed.isEmpty { parts.append("Failed: \(failed.joined(separator: ", "))") }
        banner = Banner(text: parts.joined(separator: " "), isError: !failed.isEmpty)
        await refresh()
    }

    func pull(_ wt: Worktree) async {
        busyPaths.insert(wt.path)
        let outcome = await git.pullLatest(path: wt.path)
        busyPaths.remove(wt.path)
        banner = Banner(text: outcome.message ?? (outcome.ok ? "Done." : "pull failed"), isError: !outcome.ok)
        await refresh()
    }

    func open(_ wt: Worktree) async {
        await openInStudio(path: wt.path)
    }

    func openMainRepo() async {
        await openInStudio(path: Config.mainRepo)
    }

    private func openInStudio(path: String) async {
        let outcome = await git.open(path: path, app: Config.studioApp)
        if !outcome.ok {
            banner = Banner(text: outcome.message ?? "failed to open", isError: true)
        }
    }

    // Opens the settings-selected terminal; cmux gets its smarter
    // focus-or-create-tab flow, everything else a plain `open -a`.
    func openInTerminal(_ wt: Worktree) async {
        let terminal = TerminalApps.selected
        let outcome = terminal == TerminalApps.cmuxName
            ? await git.openInCmux(path: wt.path)
            : await git.open(path: wt.path, app: terminal)
        if !outcome.ok {
            banner = Banner(text: outcome.message ?? "failed to open \(terminal)", isError: true)
        }
    }

    func resolveConflicts(_ wt: Worktree) async {
        // Marked busy because a cold cmux is started and waited for, which is
        // seconds of nothing happening otherwise.
        busyPaths.insert(wt.path)
        let outcome = await git.resolveConflicts(
            path: wt.path,
            command: Config.resolveConflictsCommand
        )
        busyPaths.remove(wt.path)
        banner = Banner(text: outcome.message ?? (outcome.ok ? "Done." : "failed to start conflict resolution"),
                        isError: !outcome.ok)
    }
}
