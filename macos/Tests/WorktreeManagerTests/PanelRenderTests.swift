import AppKit
import SwiftUI
import Testing
@testable import WorktreeManager

// The rules from DESIGN.md, asserted against real pixels: row height, the
// colour budget, and the columns that must not move. Rendered from fake data,
// so they say the same thing on any machine.
@MainActor
@Suite("Panel render")
struct PanelRenderTests {

    // Where a row's content sits inside a rendered section, in points from the
    // top: the section header, then rows of Metrics.rowHeight.
    private let sectionTop: CGFloat = 8 // the .padding(.vertical, 8)
    private let headerHeight: CGFloat = 21

    private func rowBand(_ index: Int, height: CGFloat = Metrics.rowHeight) -> Snapshot.Rect {
        let top = sectionTop + headerHeight + 3 + CGFloat(index) * Metrics.rowHeight
        return Snapshot.Rect(y: Int(top), height: Int(height))
    }

    // The two columns the row layout promises to keep: the graph gutter on the
    // left and the PR number on the right.
    private let dotColumn = Snapshot.Rect(x: Int(Metrics.gutter), width: Int(Metrics.rail) + 6)
    private let numberColumn = Snapshot.Rect(
        x: Int(Metrics.panelWidth - Metrics.gutter - Metrics.prColumn - 6),
        width: Int(Metrics.prColumn)
    )

    @Test("a branch is one line, not two")
    func rowIsOneLine() {
        // Measured, not derived from Metrics.rowHeight: a test that reads the
        // same constant the layout reads would follow it anywhere, including
        // back to the two-line row this replaced.
        func height(rows: Int) -> CGFloat {
            let (view, _) = Snapshot.section(
                worktrees: Array(SampleData.healthyWorktrees.prefix(rows)),
                pullRequests: Array(SampleData.healthyPullRequests.prefix(rows))
            )
            return CGFloat(Snapshot.render(view).height)
        }
        let perRow = (height(rows: 4) - height(rows: 2)) / 2
        #expect(abs(perRow - 24) <= 2, "one branch is one line, measured \(perRow)pt")
        #expect(perRow <= 28, "a two-line row would be nearly twice this")
        #expect(height(rows: 4) <= 150, "a header and four branches fit in 150pt")
    }

    @Test("the panel renders in both appearances", arguments: [false, true])
    func rendersInBothAppearances(dark: Bool) {
        let (view, _) = Snapshot.section(worktrees: SampleData.demoWorktrees,
                                         pullRequests: SampleData.demoPullRequests)
        let image = Snapshot.render(view, dark: dark)
        #expect(image.width == Int(Metrics.panelWidth))
        #expect(image.height >= 60, "rendered something")
        #expect(image.hasInk(in: .everything), "drew content")
    }

    // DESIGN.md: colour marks the exceptional. Nothing is wrong in this stack,
    // so nothing red, orange or amber may appear.
    @Test("a healthy stack carries no alarm colour", arguments: [false, true])
    func healthyStackIsColourless(dark: Bool) {
        let (view, _) = Snapshot.section(worktrees: SampleData.healthyWorktrees,
                                         pullRequests: SampleData.healthyPullRequests)
        let image = Snapshot.render(view, dark: dark)
        #expect(image.count { $0.isAlarm } == 0, "no warm pixels on a calm panel")
        #expect(image.count { $0 == .green } > 0, "the passing CI dots are still there")
    }

    @Test("a failing check turns its own dot red and leaves the others alone")
    func failingCheckIsLocal() {
        var prs = SampleData.healthyPullRequests
        prs[1] = SampleData.pr(2, head: "suraj/calm/second", base: "suraj/calm/first", ci: .failure)
        let (view, _) = Snapshot.section(worktrees: SampleData.healthyWorktrees, pullRequests: prs)
        let image = Snapshot.render(view)
        #expect(image.count(dotColumn.intersect(rowBand(1))) { $0 == .red } > 0,
                "the second row's dot is red")
        #expect(image.count(dotColumn.intersect(rowBand(0))) { $0 == .red } == 0,
                "the row above is untouched")
        #expect(image.count(dotColumn.intersect(rowBand(0))) { $0 == .green } > 0, "and still green")
    }

    @Test("a conflicted row shows the Resolve chip, and only with cmux")
    func resolveChipNeedsCmux() {
        var worktrees = SampleData.healthyWorktrees
        worktrees[0] = SampleData.worktree("suraj/calm/first", conflicts: true, commitsAboveTrunk: 2)

        let (withCmux, _) = Snapshot.section(worktrees: worktrees,
                                             pullRequests: SampleData.healthyPullRequests,
                                             cmuxAvailable: true)
        let (without, _) = Snapshot.section(worktrees: worktrees,
                                            pullRequests: SampleData.healthyPullRequests,
                                            cmuxAvailable: false)
        let chipRed = Snapshot.render(withCmux).count(rowBand(0)) { $0 == .red }
        let bareRed = Snapshot.render(without).count(rowBand(0)) { $0 == .red }
        #expect(chipRed > bareRed + 40, "the chip is a visible red capsule (\(chipRed) vs \(bareRed))")
        #expect(bareRed > 0, "the conflicted branch name stays red either way")
    }

    @Test("the PR number keeps its column however long the branch name is")
    func numberColumnSurvivesLongNames() {
        let long = "suraj/preview/a-branch-name-that-is-far-too-long-to-fit-on-one-line"
        let (view, _) = Snapshot.section(worktrees: [SampleData.worktree(long, commitsAboveTrunk: 2)],
                                         pullRequests: [SampleData.pr(18599, head: long)])
        let image = Snapshot.render(view)
        #expect(image.width == Int(Metrics.panelWidth), "the row didn't widen the panel")
        #expect(image.hasInk(in: numberColumn.intersect(rowBand(0))),
                "the number is still drawn in its column")
    }

    @Test("a ghost keeps its PR number; a branch with no PR gets a hollow dot")
    func ghostVersusNoPR() {
        // A ghost is a PR without a worktree, so it has CI and a number. The
        // hollow dot means the opposite thing: a branch with no PR at all.
        let prs = [SampleData.pr(1, head: "suraj/calm/first"),
                   SampleData.pr(2, head: "suraj/calm/ghost", base: "suraj/calm/first")]
        let (ghostView, store) = Snapshot.section(worktrees: [SampleData.worktree("suraj/calm/first")],
                                                  pullRequests: prs)
        #expect(store.stacks[0].nodeCount == 2, "the ghost is in the tree")
        let ghost = Snapshot.render(ghostView)
        #expect(ghost.hasInk(in: numberColumn.intersect(rowBand(1))),
                "the ghost still shows its PR number")
        #expect(ghost.count(dotColumn.intersect(rowBand(1))) { $0 == .green } > 0,
                "and its CI dot, because a ghost has a PR")

        let (localOnly, _) = Snapshot.section(
            worktrees: [SampleData.worktree("suraj/calm/first"),
                        SampleData.worktree("suraj/calm/second", commitsAboveTrunk: 6,
                                            contains: ["suraj/calm/first"])],
            pullRequests: [SampleData.pr(1, head: "suraj/calm/first")]
        )
        let bare = Snapshot.render(localOnly)
        #expect(bare.count(dotColumn.intersect(rowBand(1))) { $0 != .none } == 0,
                "a branch with no PR gets a hollow dot, no CI colour")
        // "No PR" takes the number column rather than floating mid-row, so the
        // right margin stays straight down the list.
        #expect(bare.hasInk(in: numberColumn.intersect(rowBand(1))),
                "the placeholder claims the number column")
    }

    @Test("collapsing a stack hides its rows but keeps its health visible")
    func collapsedStackKeepsHealth() {
        var prs = SampleData.healthyPullRequests
        prs[2] = SampleData.pr(3, head: "suraj/calm/third", base: "suraj/calm/second", ci: .failure)
        let (open, _) = Snapshot.section(worktrees: SampleData.healthyWorktrees, pullRequests: prs)
        let (shut, _) = Snapshot.section(worktrees: SampleData.healthyWorktrees,
                                         pullRequests: prs, collapsed: true)
        let openImage = Snapshot.render(open)
        let shutImage = Snapshot.render(shut)
        #expect(shutImage.height < openImage.height - 60, "collapsed is much shorter")
        #expect(shutImage.count { $0 == .red } > 0,
                "the health strip still shows the failure while collapsed")
    }

    @Test("opening a row adds the detail below it, not beside it")
    func expandedRowGrowsDownward() {
        let (shut, store) = Snapshot.section(worktrees: SampleData.healthyWorktrees,
                                             pullRequests: SampleData.healthyPullRequests)
        let (open, _) = Snapshot.section(worktrees: SampleData.healthyWorktrees,
                                         pullRequests: SampleData.healthyPullRequests,
                                         expandedRef: store.stacks[0].root.ref)
        let shutImage = Snapshot.render(shut)
        let openImage = Snapshot.render(open)
        #expect(openImage.height > shutImage.height + 40,
                "the expanded row is taller (\(openImage.height) vs \(shutImage.height))")
        #expect(openImage.width == shutImage.width, "and no wider")
    }

    @Test("the header badges the attention count only when there is one")
    func attentionPillAppearsOnlyWhenNeeded() {
        func header(worktrees: [Worktree], pullRequests: [PullRequest]) -> (Snapshot.Image, Int) {
            let store = Snapshot.store(worktrees: worktrees, pullRequests: pullRequests)
            return (Snapshot.render(PanelHeader().environmentObject(store)), store.attentionCount)
        }
        let (calm, calmCount) = header(worktrees: SampleData.healthyWorktrees,
                                       pullRequests: SampleData.healthyPullRequests)
        #expect(calmCount == 0, "nothing wrong")
        #expect(calm.count { $0.isAlarm } == 0, "no badge, no warm colour in the header")

        let (busy, busyCount) = header(worktrees: SampleData.demoWorktrees,
                                       pullRequests: SampleData.demoPullRequests)
        #expect(busyCount > 0, "something needs attention")
        #expect(busy.count { $0 == .orange } > 0, "the pill is drawn")
    }

    @Test("the empty state doesn't pretend to be loading")
    func emptyStateSaysSomething() {
        let empty = Snapshot.render(EmptyStateView(loaded: true))
        let loading = Snapshot.render(EmptyStateView(loaded: false))
        #expect(empty.hasInk(in: .everything), "the empty state says something")
        #expect(loading.height > 0, "the loading state renders too")
    }

    @Test("a fork is drawn under its own label, one indent deep")
    func forkedStackFits() {
        let (view, store) = Snapshot.section(worktrees: [],
                                             pullRequests: SampleData.forkedStackPullRequests)
        #expect(store.stacks[0].nodeCount == 9, "the whole tree is present")
        let image = Snapshot.render(view)
        // 4 mainline rows + 2 fork labels + 4 fork rows + a drill-in button, all
        // inside one section: still exactly one panel wide.
        #expect(image.width == Int(Metrics.panelWidth), "no horizontal overflow at depth")
        #expect(CGFloat(image.height) >= 8 * Metrics.rowHeight, "every branch got a row")
    }
}
