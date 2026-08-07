import Foundation

// What a branch row says, decided once and in one place. The view then only
// draws it — which is what makes the row's vocabulary (DESIGN.md: "colour marks
// the exceptional", "never say it twice") testable without a screenshot.
struct RowStatus: Equatable {
    // Local working-tree state, which rides on the branch name's colour.
    enum NameState: Equatable {
        case clean
        case dirty
        case conflicted
        case ghost // no worktree here
    }

    // Two different signals, one fix. `mergeInProgress` is a local merge left
    // half-done; `prVsBase` is GitHub saying the branch can no longer merge into
    // its base, with nothing started locally yet. /resolve-conflicts covers both
    // — it starts the merge itself and skips to reporting when one is already in
    // progress — so both offer the chip.
    enum Conflict: Equatable {
        case mergeInProgress
        case prVsBase
    }

    enum Review: Equatable {
        case none
        case approved
        case changesRequested
    }

    // Avatars are the loudest thing a row can carry, so they are spent only on
    // threads waiting for a reply; a plain human comment gets a quiet bubble.
    enum Comments: Equatable {
        case none
        case bubble
        case unresolved(threads: Int, people: [Commenter])
    }

    var nameState: NameState
    var conflict: Conflict?
    var showsResolveChip: Bool
    // The skill refuses to start a merge on a dirty tree, so a click would burn
    // a cmux tab and an agent turn to be told that. Only applies before the
    // merge exists — once it's in progress the conflicted files *are* the dirt.
    var blockedByDirtyTree: Bool
    var isDraft: Bool
    var showsConflictWarning: Bool
    var review: Review
    var comments: Comments
    var dirtyCount: Int
    var unpushed: Int
    var prNumber: Int?
    // Stands in for the status glyphs when there are none to show.
    var placeholder: String?

    init(node: StackNode, resolveEnabled: Bool) {
        let wt = node.worktree
        let pr = node.pr

        if wt == nil {
            nameState = .ghost
        } else if wt?.conflicts == true {
            nameState = .conflicted
        } else if wt?.dirty == true {
            nameState = .dirty
        } else {
            nameState = .clean
        }

        if wt?.conflicts == true {
            conflict = .mergeInProgress
        } else if pr?.mergeable == .conflicting {
            conflict = .prVsBase
        } else {
            conflict = nil
        }

        // A ghost row has no working tree to resolve anything in.
        showsResolveChip = conflict != nil && resolveEnabled && wt != nil
        blockedByDirtyTree = conflict == .prVsBase && wt?.dirty == true

        isDraft = pr?.isDraft ?? false
        showsConflictWarning = pr?.mergeable == .conflicting

        // REVIEW_REQUIRED is the default on almost every open PR, so only the
        // states that actually changed something are worth a badge.
        switch pr?.review {
        case .approved: review = .approved
        case .changesRequested: review = .changesRequested
        default: review = .none
        }

        comments = Self.comments(for: pr)

        dirtyCount = wt?.dirty == true ? (wt?.dirtyCount ?? 0) : 0
        unpushed = wt?.unpushed ?? 0
        prNumber = pr?.number

        if pr == nil {
            placeholder = wt == nil ? nil : "No PR"
        } else if wt == nil {
            placeholder = "No worktree"
        } else {
            placeholder = nil
        }
    }

    // Four bots comment on every single PR in this repo, so lighting up whenever
    // `participants` is non-empty told you nothing: it lit all 22 rows. Only an
    // unresolved thread (whoever opened it) or a human other than you qualifies.
    private static func comments(for pr: PullRequest?) -> Comments {
        guard let pr else { return .none }
        let waiting = pr.participants.filter { $0.unresolved > 0 }
        if !waiting.isEmpty {
            return .unresolved(threads: pr.unresolvedThreads, people: waiting)
        }
        let humans = pr.participants.contains { !$0.isBot && !$0.isViewer && $0.comments > 0 }
        return humans ? .bubble : .none
    }

    // True when the row draws nothing but its name and number — the healthy
    // case, and the one the panel should be mostly made of.
    var isQuiet: Bool {
        !isDraft && !showsConflictWarning && review == .none
            && comments == .none && conflict == nil
            && dirtyCount == 0 && unpushed == 0
    }
}

// PR data is polled every 30 minutes, so the age of it is worth a word in the
// header. Pure, and takes `now`, so the wording can be tested.
enum PRFreshness {
    static func label(fetchedAt: Date?, now: Date = Date()) -> String {
        guard let fetchedAt else { return "PRs not fetched" }
        let minutes = Int(now.timeIntervalSince(fetchedAt) / 60)
        if minutes < 1 { return "PRs just now" }
        if minutes < 60 { return "PRs \(minutes)m ago" }
        return "PRs \(minutes / 60)h ago"
    }
}
