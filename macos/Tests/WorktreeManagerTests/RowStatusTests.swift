import Foundation
import Testing
@testable import WorktreeManager

// What each row says, per DESIGN.md's vocabulary. These are the assertions a
// screenshot can't make: which glyph appears, and — more importantly — which
// one stays away.
@Suite("Row vocabulary")
struct RowStatusTests {

    private func node(
        _ ref: String = "feature/thing",
        wt: Worktree? = SampleData.worktree("feature/thing"),
        pr: PullRequest? = SampleData.pr(1, head: "feature/thing")
    ) -> StackNode {
        StackNode(ref: ref, worktree: wt, pr: pr)
    }

    private func status(_ node: StackNode, resolveEnabled: Bool = true) -> RowStatus {
        RowStatus(node: node, resolveEnabled: resolveEnabled)
    }

    @Test("a healthy row is quiet")
    func healthyRowIsQuiet() {
        let s = status(node())
        #expect(s.isQuiet, "a healthy row draws no status glyphs at all")
        #expect(s.nameState == .clean)
        #expect(s.prNumber == 1)
        #expect(s.placeholder == nil)
        #expect(s.comments == .none)
    }

    @Test("uncommitted work colours the name and shows counts")
    func dirtyWorktree() {
        let wt = SampleData.worktree("feature/thing", dirty: 12, unpushed: 2)
        let s = status(node(wt: wt))
        #expect(s.nameState == .dirty)
        #expect(s.dirtyCount == 12)
        #expect(s.unpushed == 2)
        #expect(!s.isQuiet)
    }

    @Test("a half-done local merge offers Resolve")
    func localMergeConflict() {
        let wt = SampleData.worktree("feature/thing", dirty: 4, conflicts: true)
        let s = status(node(wt: wt))
        #expect(s.nameState == .conflicted, "conflict beats dirty on the name")
        #expect(s.conflict == .mergeInProgress)
        #expect(s.showsResolveChip)
        #expect(!s.blockedByDirtyTree,
                "an in-progress merge isn't blocked — the conflicted files are the dirt")
    }

    @Test("a PR conflicting with its base offers Resolve and warns")
    func prConflictsWithBase() {
        let pr = SampleData.pr(2, head: "feature/thing", mergeable: .conflicting)
        let s = status(node(pr: pr))
        #expect(s.conflict == .prVsBase)
        #expect(s.showsConflictWarning)
        #expect(s.showsResolveChip)
        #expect(!s.blockedByDirtyTree, "clean tree, so the merge can start")
    }

    @Test("a conflicting PR on a dirty tree warns that the merge won't start")
    func prConflictOnDirtyTree() {
        let pr = SampleData.pr(2, head: "feature/thing", mergeable: .conflicting)
        let wt = SampleData.worktree("feature/thing", dirty: 3)
        let s = status(node(wt: wt, pr: pr))
        #expect(s.blockedByDirtyTree)
        #expect(s.showsResolveChip, "the chip still shows, with the warning in its tooltip")
    }

    @Test("Resolve stays hidden without cmux")
    func resolveNeedsCmux() {
        let wt = SampleData.worktree("feature/thing", conflicts: true)
        let s = status(node(wt: wt), resolveEnabled: false)
        #expect(!s.showsResolveChip)
        #expect(s.conflict == .mergeInProgress, "the conflict itself is still reported")
    }

    @Test("an unknown mergeable state is not a conflict")
    func unknownMergeability() {
        // GitHub returns UNKNOWN while it runs the background merge test.
        let pr = SampleData.pr(3, head: "feature/thing", mergeable: .unknown)
        let s = status(node(pr: pr))
        #expect(s.conflict == nil, "UNKNOWN must not read as CONFLICTING")
        #expect(!s.showsConflictWarning)
    }

    @Test("a ghost row says No worktree and offers nothing to resolve")
    func ghostRow() {
        let pr = SampleData.pr(4, head: "feature/thing", mergeable: .conflicting)
        let s = status(node(wt: nil, pr: pr))
        #expect(s.nameState == .ghost)
        #expect(s.placeholder == "No worktree")
        #expect(!s.showsResolveChip, "nothing local to resolve in")
        #expect(s.prNumber == 4, "the PR number is still shown")
    }

    @Test("a branch with no PR says No PR")
    func noPullRequest() {
        let s = status(node(pr: nil))
        #expect(s.placeholder == "No PR")
        #expect(s.prNumber == nil)
        #expect(s.comments == .none)
    }

    @Test("bot chatter alone shows nothing")
    func botsStaySilent() {
        // Four bots comment on every PR in this repo; a count lit all 22 rows.
        let pr = SampleData.pr(5, head: "feature/thing",
                               participants: [SampleData.bot("size-report", comments: 3),
                                              SampleData.bot("danger", comments: 1)])
        #expect(status(node(pr: pr)).comments == .none)
    }

    @Test("your own comments show nothing")
    func viewerCommentsStaySilent() {
        let pr = SampleData.pr(6, head: "feature/thing",
                               participants: [SampleData.person("me", comments: 4, isViewer: true)])
        #expect(status(node(pr: pr)).comments == .none, "nothing there is waiting on you")
    }

    @Test("a human comment gets the quiet bubble")
    func humanCommentBubble() {
        let pr = SampleData.pr(7, head: "feature/thing",
                               participants: [SampleData.person("reviewer", comments: 2),
                                              SampleData.bot("size-report", comments: 9)])
        #expect(status(node(pr: pr)).comments == .bubble, "bubble, no avatars")
    }

    @Test("unresolved threads spend the avatars — bot or not")
    func unresolvedThreadsGetAvatars() throws {
        let reviewer = SampleData.person("reviewer", unresolved: 2, comments: 2)
        let bot = SampleData.bot("lint-bot", unresolved: 1)
        let chatty = SampleData.bot("size-report", comments: 5)
        let pr = SampleData.pr(8, head: "feature/thing",
                               unresolved: 3, participants: [reviewer, bot, chatty])
        guard case .unresolved(let threads, let people) = status(node(pr: pr)).comments else {
            Issue.record("expected the unresolved case")
            return
        }
        #expect(threads == 3)
        #expect(people.count == 2, "only those with unresolved threads")
        #expect(!people.contains { $0.login == "size-report" }, "the chatty bot is left out")
    }

    // REVIEW_REQUIRED is the default on almost every open PR, so only the states
    // that actually changed something are worth a badge.
    @Test("review badges only for states that changed something", arguments: [
        (ReviewState.approved, RowStatus.Review.approved),
        (ReviewState.changesRequested, RowStatus.Review.changesRequested),
        (ReviewState.reviewRequired, RowStatus.Review.none),
        (ReviewState.none, RowStatus.Review.none),
    ])
    func reviewBadges(state: ReviewState, expected: RowStatus.Review) {
        let pr = SampleData.pr(9, head: "feature/thing", review: state)
        #expect(status(node(pr: pr)).review == expected)
    }

    @Test("draft is carried through")
    func draftFlag() {
        let pr = SampleData.pr(10, head: "feature/thing", draft: true)
        let s = status(node(pr: pr))
        #expect(s.isDraft)
        #expect(!s.isQuiet)
    }

    @Test("PR freshness wording")
    func freshnessWording() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(PRFreshness.label(fetchedAt: nil, now: now) == "PRs not fetched")
        #expect(PRFreshness.label(fetchedAt: now.addingTimeInterval(-20), now: now) == "PRs just now")
        #expect(PRFreshness.label(fetchedAt: now.addingTimeInterval(-300), now: now) == "PRs 5m ago")
        #expect(PRFreshness.label(fetchedAt: now.addingTimeInterval(-7200), now: now) == "PRs 2h ago")
    }
}
