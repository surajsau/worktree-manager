import Foundation
import Testing
@testable import WorktreeManager

// The store driven entirely by fakes: what the buttons in the panel actually do,
// asserted on the calls the fake repository recorded.
@MainActor
@Suite("Store")
struct StoreTests {

    private struct Rig {
        let store: Store
        let git: FakeWorktreeRepository
        let github: FakePullRequestRepository
        let cache: InMemoryPRSnapshotStore
        let avatars: RecordingAvatarLoader
    }

    private func rig(
        worktrees: [Worktree] = SampleData.demoWorktrees,
        pullRequests: [PullRequest] = SampleData.demoPullRequests,
        cached: PRSnapshot? = nil
    ) -> Rig {
        let git = FakeWorktreeRepository(worktrees)
        let github = FakePullRequestRepository(pullRequests)
        let cache = InMemoryPRSnapshotStore(cached)
        let avatars = RecordingAvatarLoader()
        return Rig(store: Store(git: git, github: github, cache: cache, avatars: avatars),
                   git: git, github: github, cache: cache, avatars: avatars)
    }

    private func deletes(_ git: FakeWorktreeRepository) -> Int {
        git.callCount { if case .delete = $0 { return true } else { return false } }
    }

    @Test("refresh reads the repository and builds the tree")
    func refreshBuildsTree() async {
        let r = rig(pullRequests: [])
        #expect(!r.store.hasLoadedOnce)
        await r.store.refresh()
        #expect(r.store.hasLoadedOnce)
        #expect(r.store.worktrees.count == SampleData.demoWorktrees.count)
        #expect(r.git.callCount { $0 == .list } == 1)
        #expect(!r.store.stacks.isEmpty)
        #expect(r.store.mergedWorktrees.count == 2, "the merged pair is separated out")
    }

    @Test("the cached snapshot is on screen before the first fetch")
    func cachedSnapshotShownFirst() {
        let snapshot = PRSnapshot(pullRequests: SampleData.demoPullRequests,
                                  fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let r = rig(cached: snapshot)
        #expect(r.store.pullRequests.count == SampleData.demoPullRequests.count)
        #expect(r.store.prFetchedAt != nil, "with their age")
        #expect(r.github.fetches == 0, "no fetch needed to show them")
    }

    @Test("a fresh cache is not re-fetched when the menu opens")
    func freshCacheIsNotRefetched() async {
        let r = rig(cached: PRSnapshot(pullRequests: SampleData.demoPullRequests, fetchedAt: Date()))
        await r.store.refreshOnOpen()
        #expect(r.github.fetches == 0, "inside the poll window, opening the menu costs nothing")
    }

    @Test("a stale cache is re-fetched when the menu opens")
    func staleCacheIsRefetched() async {
        let old = Date().addingTimeInterval(-Config.prPollInterval - 60)
        let r = rig(cached: PRSnapshot(pullRequests: [], fetchedAt: old))
        await r.store.refreshOnOpen()
        #expect(r.github.fetches == 1)
    }

    @Test("a successful PR fetch caches and prefetches avatars")
    func successfulFetchCaches() async {
        let r = rig()
        await r.store.refreshPullRequests()
        #expect(r.store.pullRequests.count == SampleData.demoPullRequests.count)
        #expect(r.store.prError == nil)
        #expect(r.cache.saves == 1, "written to the snapshot store")
        #expect(!r.avatars.requested.isEmpty, "avatars prefetched, so the render isn't grey")
    }

    @Test("a failed PR fetch keeps the stale rows and says why")
    func failedFetchKeepsStaleRows() async {
        let r = rig(cached: PRSnapshot(pullRequests: SampleData.demoPullRequests, fetchedAt: Date()))
        r.github.fail("gh CLI not found")
        await r.store.refreshPullRequests()
        #expect(r.store.pullRequests.count == SampleData.demoPullRequests.count,
                "stale numbers beat none")
        #expect(r.store.prError == "gh CLI not found")
    }

    @Test("the attention count counts branches, not signals")
    func attentionCountIsDeduplicated() async {
        let r = rig()
        await r.store.refresh()
        await r.store.refreshPullRequests()
        // Demo data: one failing CI, two PRs with unresolved threads, and one
        // branch that is both a conflicting PR and a half-done local merge —
        // which is one thing to go and fix, not two.
        #expect(r.store.attentionCount == 4)
    }

    @Test("refreshing everything fetches the trunk first")
    func refreshEverythingFetchesTrunk() async {
        let r = rig()
        await r.store.refreshEverything()
        #expect(r.git.callCount { $0 == .fetchTrunk } == 1,
                "a stale origin/main under-reports merges")
        #expect(r.github.fetches == 1)
    }

    @Test("create runs the script, banners, and re-reads")
    func createWorktree() async {
        let r = rig(worktrees: [])
        let outcome = await r.store.create(name: "new-thing", base: "origin/main")
        #expect(outcome.ok)
        #expect(r.git.callCount { $0 == .create(name: "new-thing", base: "origin/main") } == 1)
        #expect(r.store.banner?.text == "Created \(Config.branchPrefix)new-thing.")
        #expect(r.store.worktrees.count == 1, "the list was re-read afterwards")
    }

    @Test("a failed create reports the error and creates nothing")
    func failedCreate() async {
        let r = rig(worktrees: [])
        r.git.nextOutcome = OpOutcome(ok: false, message: "branch already exists")
        let outcome = await r.store.create(name: "dupe", base: nil)
        #expect(!outcome.ok)
        #expect(outcome.message == "branch already exists", "passed back to the form")
        #expect(r.store.banner == nil, "no success banner")
        #expect(r.store.worktrees.isEmpty)
    }

    @Test("delete removes the worktree and clears its busy state")
    func deleteWorktree() async {
        let r = rig(pullRequests: [])
        await r.store.refresh()
        let target = r.store.worktrees[0]
        // Captured while the delete is in flight: the row shows a spinner.
        nonisolated(unsafe) var busyDuring = false
        r.git.onDelete = { _ in busyDuring = true }
        await r.store.delete(target)
        #expect(busyDuring, "the row was marked busy while deleting")
        #expect(!r.store.busyPaths.contains(target.path), "and cleared afterwards")
        #expect(r.git.callCount { $0 == .delete(path: target.path, branch: target.branch) } == 1)
        #expect(!r.store.worktrees.contains { $0.path == target.path })
    }

    @Test("prune deletes only the branches with nothing to lose")
    func pruneSkipsLocalWork() async {
        let r = rig(pullRequests: [])
        await r.store.refresh()
        let candidates = r.store.mergedWorktrees
        #expect(candidates.count == 2, "two merged branches, one of them dirty")
        await r.store.pruneMerged(candidates)
        #expect(deletes(r.git) == 1, "the dirty one is skipped")
        #expect(r.store.banner?.text.contains("1 skipped") == true,
                "and the skip is reported: \(r.store.banner?.text ?? "no banner")")
    }

    @Test("prune re-checks its candidates instead of trusting the view")
    func pruneReChecks() async {
        let r = rig(pullRequests: [])
        await r.store.refresh()
        // A stale snapshot from the view: this branch is not merged at all.
        await r.store.pruneMerged([SampleData.worktree("suraj/live/branch", commitsAboveTrunk: 4)])
        #expect(deletes(r.git) == 0, "a destructive batch verifies every member")
        #expect(r.store.banner?.text == "Nothing to prune.")
    }

    @Test("pull merges the trunk into one worktree")
    func pullLatest() async {
        let r = rig(pullRequests: [])
        await r.store.refresh()
        let target = r.store.worktrees[0]
        await r.store.pull(target)
        #expect(r.git.callCount { $0 == .pull(path: target.path) } == 1)
        #expect(!r.store.busyPaths.contains(target.path))
    }

    @Test("opening a terminal routes cmux through its own flow")
    func terminalRouting() async {
        let r = rig(pullRequests: [])
        await r.store.refresh()
        let target = r.store.worktrees[0]

        UserDefaults.standard.set(TerminalApps.cmuxName, forKey: SettingsKeys.terminalApp)
        await r.store.openInTerminal(target)
        #expect(r.git.callCount { $0 == .openInCmux(path: target.path) } == 1,
                "cmux gets focus-or-create, not `open -a`")

        UserDefaults.standard.set("Terminal", forKey: SettingsKeys.terminalApp)
        await r.store.openInTerminal(target)
        #expect(r.git.callCount { $0 == .open(path: target.path, app: "Terminal") } == 1,
                "everything else is a plain open")
        UserDefaults.standard.removeObject(forKey: SettingsKeys.terminalApp)
    }

    @Test("a failed open surfaces an error banner")
    func failedOpen() async {
        let r = rig(pullRequests: [])
        await r.store.refresh()
        r.git.nextOutcome = OpOutcome(ok: false, message: "Android Studio is not installed")
        await r.store.open(r.store.worktrees[0])
        #expect(r.store.banner?.isError == true)
        #expect(r.store.banner?.text == "Android Studio is not installed")
    }

    @Test("resolve conflicts hands the worktree to the agent command")
    func resolveConflicts() async throws {
        let r = rig(pullRequests: [])
        await r.store.refresh()
        let target = try #require(r.store.worktrees.first { $0.conflicts },
                                  "the demo data has a conflicted worktree")
        await r.store.resolveConflicts(target)
        #expect(r.git.callCount {
            $0 == .resolveConflicts(path: target.path, command: Config.resolveConflictsCommand)
        } == 1, "one cmux workspace, running the configured command")
        #expect(!r.store.busyPaths.contains(target.path))
    }

    @Test("base branches load without fetching")
    func baseBranchesAreCheap() async {
        let r = rig()
        await r.store.loadBaseBranches()
        #expect(r.store.baseBranches == ["origin/main", "origin/minor"])
        #expect(r.git.callCount { $0 == .fetchTrunk } == 0, "cheap enough to redo — no fetch")
    }
}
