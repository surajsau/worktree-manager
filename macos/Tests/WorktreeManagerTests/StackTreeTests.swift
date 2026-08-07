import Testing
@testable import WorktreeManager

// How branches become stacks, and how a stack becomes rows. All from fake data
// — no repo, no `gh`.
@Suite("Stack tree")
struct StackTreeTests {

    private func build(_ worktrees: [Worktree], _ prs: [PullRequest]) -> (stacks: [Stack], merged: [Worktree]) {
        StackBuilder.build(worktrees: worktrees, pullRequests: prs)
    }

    private func refs(_ node: StackNode) -> [String] {
        [node.ref] + node.children.flatMap(refs)
    }

    @Test("a PR's base wins over the commit graph")
    func prBaseWins() {
        // b contains a's tip, so the graph would make a its parent — but b's PR
        // says it merges into main, which is what GitHub will actually do.
        let a = SampleData.worktree("a", commitsAboveTrunk: 2)
        let b = SampleData.worktree("b", commitsAboveTrunk: 5, contains: ["a"])
        let tree = build([a, b], [SampleData.pr(1, head: "b", base: "main")])
        #expect(tree.stacks.count == 2, "two stacks, not one chain")
    }

    @Test("a branch with no PR gets its parent from the commit graph")
    func inferredParent() {
        let a = SampleData.worktree("a", commitsAboveTrunk: 2)
        let b = SampleData.worktree("b", commitsAboveTrunk: 5, contains: ["a"])
        let tree = build([a, b], [])
        #expect(tree.stacks.count == 1)
        #expect(refs(tree.stacks[0].root) == ["a", "b"], "b sits on a")
    }

    @Test("the nearest ancestor wins when several are contained")
    func nearestAncestor() {
        let a = SampleData.worktree("a", commitsAboveTrunk: 2)
        let b = SampleData.worktree("b", commitsAboveTrunk: 5, contains: ["a"])
        let c = SampleData.worktree("c", commitsAboveTrunk: 9, contains: ["a", "b"])
        #expect(refs(build([a, b, c], []).stacks[0].root) == ["a", "b", "c"], "c sits on b, not on a")
    }

    @Test("a ghost PR keeps a chain in one piece")
    func ghostHoldsTheChain() {
        // The middle branch isn't checked out. Without a row for it the chain
        // would break in two.
        let bottom = SampleData.worktree("bottom", commitsAboveTrunk: 2)
        let top = SampleData.worktree("top", commitsAboveTrunk: 8)
        let prs = [
            SampleData.pr(1, head: "bottom", base: "main"),
            SampleData.pr(2, head: "middle", base: "bottom"),
            SampleData.pr(3, head: "top", base: "middle"),
        ]
        let tree = build([bottom, top], prs)
        #expect(tree.stacks.count == 1)
        #expect(refs(tree.stacks[0].root) == ["bottom", "middle", "top"])
        #expect(tree.stacks[0].root.children.first?.isGhost == true)
    }

    @Test("merged branches are pulled out of the stacks")
    func mergedSeparated() {
        let live = SampleData.worktree("live", commitsAboveTrunk: 3)
        let merged = SampleData.worktree("merged", commitsAboveTrunk: 0, hasOwnCommits: true)
        let tree = build([live, merged], [])
        #expect(tree.merged.map(\.branch) == ["merged"])
        #expect(tree.stacks.count == 1, "the merged branch gets no stack")
    }

    @Test("a fresh branch with no commits is not merged")
    func freshBranchIsNotMerged() {
        // Zero commits above the trunk means one of two opposite things; the
        // reflog is what tells them apart.
        let fresh = SampleData.worktree("fresh", commitsAboveTrunk: 0, hasOwnCommits: false)
        let tree = build([fresh], [])
        #expect(tree.merged.isEmpty, "not swept into Merged")
        #expect(tree.stacks.count == 1, "it gets a stack of its own")
    }

    @Test("stacks are ordered by latest PR activity")
    func orderedByActivity() {
        let prs = [
            SampleData.pr(1, head: "old", base: "main", updatedMinutesAgo: 600),
            SampleData.pr(2, head: "recent", base: "main", updatedMinutesAgo: 1),
        ]
        #expect(build([], prs).stacks.map(\.root.ref) == ["recent", "old"])
    }

    @Test("a stack is titled by the folder of its bottom branch")
    func stackTitle() {
        let prs = [
            SampleData.pr(1, head: "suraj/preview/enable-flag", base: "main"),
            SampleData.pr(2, head: "suraj/preview/spot-card", base: "suraj/preview/enable-flag"),
        ]
        let stack = build([], prs).stacks[0]
        #expect(stack.title == "preview", "the folder survives new slices landing on top")
        #expect(stack.root.leaf == "enable-flag", "leaf kept alongside")
        #expect(stack.nodeCount == 2)
    }

    @Test("a branch with no folder keeps its leaf as the title")
    func leafTitleFallback() {
        let stack = build([], [SampleData.pr(1, head: "suraj/realtime-task-2", base: "main")]).stacks[0]
        #expect(stack.title == "realtime-task-2", "nothing else to go on")
    }

    @Test("attention propagates up the stack")
    func attentionPropagates() {
        let prs = [
            SampleData.pr(1, head: "bottom", base: "main"),
            SampleData.pr(2, head: "top", base: "bottom", ci: .failure),
        ]
        #expect(build([], prs).stacks[0].needsAttention, "a failure anywhere marks the stack")
        #expect(!build([], [SampleData.pr(3, head: "fine", base: "main")]).stacks[0].needsAttention)
    }

    @Test("a cycle in PR bases doesn't hang the build")
    func cycleTerminates() {
        let prs = [
            SampleData.pr(1, head: "a", base: "b"),
            SampleData.pr(2, head: "b", base: "a"),
        ]
        #expect(build([], prs).stacks.count <= 2, "terminates with a bounded result")
    }

    @Test("the mainline is the biggest subtree, flat")
    func mainlineIsFlat() {
        let stack = build([], SampleData.forkedStackPullRequests).stacks[0]
        #expect(StackLayout(root: stack.root).mainline.map(\.ref) == ["a", "b", "d", "f"])
        #expect(stack.nodeCount == 9, "every branch is in the stack")
    }

    @Test("a fork is labelled with its branch point")
    func forkLabelling() {
        let layout = StackLayout(root: build([], SampleData.forkedStackPullRequests).stacks[0].root)
        #expect(layout.forks.count == 2, "two forks off the mainline")
        let offA = layout.forks.first { $0.parentLeaf == "a" }
        #expect(offA?.chain.map(\.ref) == ["c", "g", "h"], "the fork's own chain runs flat")
    }

    @Test("a fork inside a fork becomes a drill-in instead of a third indent")
    func deepForkDrillsIn() {
        let layout = StackLayout(root: build([], SampleData.forkedStackPullRequests).stacks[0].root)
        #expect(layout.forks.first { $0.parentLeaf == "a" }?.deeper.map(\.ref) == ["i"])
        #expect(layout.forks.first { $0.parentLeaf == "b" }?.deeper.isEmpty == true)
    }

    @Test("the collapsed health strip reports every branch")
    func healthStripCoversEverything() {
        let stack = build([], SampleData.forkedStackPullRequests).stacks[0]
        var states: [CIState?] = []
        func walk(_ node: StackNode) {
            states.append(node.pr?.ci)
            node.children.forEach(walk)
        }
        walk(stack.root)
        #expect(states.count == 9, "one dot per branch, forks included")
        #expect(states.compactMap { $0 }.filter { $0 == .failure }.count == 1,
                "the failure is visible while collapsed")
    }
}
