import Foundation

// Fake worktrees and pull requests: everything the panel can show, with no git
// repo, no GitHub and no network. Used by `--test`, by `--render --demo` (so
// the design can be iterated on any machine) and by `--stacks-selftest`.
//
// Kept in the app target rather than a test target on purpose: this project
// builds with Command Line Tools only, where XCTest doesn't exist, so the tests
// ride along in the binary behind `--test`.
enum SampleData {

    // MARK: - Builders

    static func worktree(
        _ branch: String,
        dirty: Int = 0,
        conflicts: Bool = false,
        unpushed: Int = 0,
        behindTrunk: Int = 0,
        commitsAboveTrunk: Int = 3,
        hasOwnCommits: Bool = true,
        contains: [String] = [],
        tip: String? = nil
    ) -> Worktree {
        let slug = branch.replacingOccurrences(of: "/", with: "+")
        return Worktree(
            branch: branch,
            name: branch,
            path: "/tmp/worktrees/\(slug)",
            folder: slug,
            dirty: dirty > 0,
            dirtyCount: dirty,
            conflicts: conflicts,
            ahead: 0,
            behind: 0,
            unpushed: unpushed,
            ticketPath: nil,
            shipRunPath: nil,
            commitsAboveTrunk: commitsAboveTrunk,
            hasOwnCommits: hasOwnCommits,
            behindTrunk: behindTrunk,
            tip: tip ?? "tip-\(slug)",
            containedTips: Set(contains.map { "tip-" + $0.replacingOccurrences(of: "/", with: "+") })
        )
    }

    static func pr(
        _ number: Int,
        head: String,
        base: String = "main",
        title: String? = nil,
        ci: CIState = .success,
        draft: Bool = false,
        mergeable: Mergeability = .mergeable,
        review: ReviewState = .none,
        unresolved: Int = 0,
        participants: [Commenter] = [],
        additions: Int = 40,
        deletions: Int = 12,
        updatedMinutesAgo: Int = 0
    ) -> PullRequest {
        PullRequest(
            number: number,
            title: title ?? "Sample PR for \(head)",
            url: "https://example.invalid/pull/\(number)",
            headRef: head,
            baseRef: base,
            isDraft: draft,
            mergeable: mergeable,
            review: review,
            ci: ci,
            unresolvedThreads: unresolved,
            additions: additions,
            deletions: deletions,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(updatedMinutesAgo) * 60),
            participants: participants
        )
    }

    static func person(_ login: String, unresolved: Int = 0, comments: Int = 0, isViewer: Bool = false) -> Commenter {
        Commenter(login: login, avatarURL: "https://example.invalid/\(login).png",
                  isBot: false, isViewer: isViewer, unresolved: unresolved, comments: comments)
    }

    static func bot(_ login: String, unresolved: Int = 0, comments: Int = 1) -> Commenter {
        Commenter(login: login, avatarURL: "https://example.invalid/\(login).png",
                  isBot: true, isViewer: false, unresolved: unresolved, comments: comments)
    }

    // MARK: - Scenarios

    // Two stacks, a ghost, a branch with no PR, and a merged pair — one of them
    // carrying local work so the prune has something to skip.
    static var demoWorktrees: [Worktree] {
        [
            worktree("preview/enable-device-flag", behindTrunk: 117, commitsAboveTrunk: 2),
            worktree("preview/spot-card-presenter", commitsAboveTrunk: 4),
            worktree("preview/memory-management", dirty: 3, commitsAboveTrunk: 6),
            worktree("preview/coordinator-rewrite", commitsAboveTrunk: 8,
                     contains: ["preview/memory-management"]),
            worktree("shared-player/screen-restart-tests", commitsAboveTrunk: 2),
            worktree("shared-player/activity-cleanup", dirty: 12, conflicts: true,
                     unpushed: 1, commitsAboveTrunk: 5),
            worktree("episode-list/anchored-series", commitsAboveTrunk: 3),
            worktree("merged/tab-frame", commitsAboveTrunk: 0),
            worktree("merged/focus-fix", dirty: 2, commitsAboveTrunk: 0),
        ]
    }

    static var demoPullRequests: [PullRequest] {
        [
            pr(18565, head: "preview/enable-device-flag",
               title: "Add the device flag behind a preview toggle",
               unresolved: 1, participants: [person("a-reviewer", unresolved: 1)], updatedMinutesAgo: 5),
            pr(18566, head: "preview/spot-card-presenter", base: "preview/enable-device-flag",
               ci: .failure, review: .approved,
               participants: [bot("size-report"), person("a-reviewer", comments: 2)], updatedMinutesAgo: 20),
            pr(18576, head: "preview/memory-management", base: "preview/spot-card-presenter",
               ci: .pending, draft: true, updatedMinutesAgo: 45),
            // No PR for coordinator-rewrite: its parent comes from the commit graph.
            pr(18580, head: "shared-player/screen-restart-tests", updatedMinutesAgo: 10),
            pr(18584, head: "shared-player/activity-cleanup",
               base: "shared-player/screen-restart-tests",
               mergeable: .conflicting, review: .changesRequested, updatedMinutesAgo: 30),
            // Ghost: a PR whose branch isn't checked out here. Without it the
            // chain below would break in two.
            pr(18595, head: "shared-player/move-liveevent", base: "shared-player/activity-cleanup",
               draft: true, updatedMinutesAgo: 60),
            pr(18572, head: "episode-list/anchored-series", ci: .pending, draft: true,
               unresolved: 2, participants: [bot("lint-bot", unresolved: 2)], updatedMinutesAgo: 90),
        ]
    }

    // Everything healthy: no failures, drafts, conflicts or review noise. The
    // baseline for "a quiet panel carries no warm colour".
    static var healthyWorktrees: [Worktree] {
        [
            worktree("calm/first", commitsAboveTrunk: 2),
            worktree("calm/second", commitsAboveTrunk: 4),
            worktree("calm/third", commitsAboveTrunk: 6),
            worktree("calm/fourth", commitsAboveTrunk: 8),
        ]
    }

    static var healthyPullRequests: [PullRequest] {
        [
            pr(1, head: "calm/first"),
            pr(2, head: "calm/second", base: "calm/first"),
            pr(3, head: "calm/third", base: "calm/second"),
            pr(4, head: "calm/fourth", base: "calm/third"),
        ]
    }

    //  main → a ─┬─ b ─┬─ d ─ f      (b/d/f is the mainline: biggest subtree)
    //            │     └─ e          (fork inside the mainline)
    //            └─ c ─ g ─┬─ h      (fork off a; h continues its chain)
    //                      └─ i      (fork inside a fork => drill-in)
    static let forkEdges = [("a", "main"), ("b", "a"), ("c", "a"), ("d", "b"),
                            ("e", "b"), ("f", "d"), ("g", "c"), ("h", "g"), ("i", "g")]

    static var forkedStackPullRequests: [PullRequest] {
        forkEdges.enumerated().map { index, edge in
            pr(100 + index, head: edge.0, base: edge.1,
               ci: index == 2 ? .failure : (index == 4 ? .pending : .success),
               draft: index % 3 == 0,
               review: index == 1 ? .approved : .none,
               unresolved: index == 3 ? 2 : 0,
               participants: index == 3 ? [person("a-reviewer", unresolved: 2)] : [],
               updatedMinutesAgo: index)
        }
    }
}
