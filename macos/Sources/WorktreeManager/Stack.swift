import Foundation

// A branch in a stack. Either side can be missing: a worktree with no PR is a
// local-only branch, and a PR with no worktree is a "ghost" — a link in the
// stack that isn't checked out here. Ghosts matter: without them a chain like
// …→#18579→#18580→#18581 breaks in two when #18580 has no local worktree.
struct StackNode: Identifiable, Sendable {
    let ref: String
    var worktree: Worktree?
    var pr: PullRequest?
    var children: [StackNode] = []

    var id: String { ref }
    var isGhost: Bool { worktree == nil }

    // Last path segment, with the user's branch prefix dropped — the whole
    // branch path never fits and the tail is what distinguishes siblings.
    var leaf: String {
        ref.split(separator: "/").last.map(String.init) ?? ref
    }

    var subtreeCount: Int {
        1 + children.reduce(0) { $0 + $1.subtreeCount }
    }

    // Worst state anywhere below (and including) this node, for the collapsed
    // header of a stack.
    var needsAttention: Bool {
        let mine = pr.map { $0.ci == .failure || $0.mergeable == .conflicting || $0.unresolvedThreads > 0 } ?? false
        return mine || (worktree?.conflicts ?? false) || children.contains { $0.needsAttention }
    }
}

// One stack: a single chain (plus its forks) sitting on a trunk ref. Grouping
// by trunk instead would put all 22 PRs that happen to sit on main into one
// 23-row card, which is the opposite of a clear view.
struct Stack: Identifiable, Sendable {
    let trunk: String
    var root: StackNode

    var id: String { root.ref }
    var nodeCount: Int { root.subtreeCount }
    var prCount: Int { Self.prs(in: root) }
    var needsAttention: Bool { root.needsAttention }

    // What the stack is called: the branch folder of the bottom branch, e.g.
    // "preview" for preview/enable-device-flag (any configured branch prefix
    // dropped first). That is the piece of work the whole stack belongs to,
    // where the leaf only names its first slice — and it stays put as slices are
    // added on top. Branches with no folder (realtime-player-task-2) have
    // nothing else to go on, so they keep the leaf.
    var title: String {
        var segments = root.ref
        if segments.hasPrefix(Config.branchPrefix) {
            segments = String(segments.dropFirst(Config.branchPrefix.count))
        }
        let folders = segments.split(separator: "/").dropLast()
        return folders.isEmpty ? root.leaf : folders.joined(separator: "/")
    }

    private static func prs(in node: StackNode) -> Int {
        (node.pr == nil ? 0 : 1) + node.children.reduce(0) { $0 + prs(in: $1) }
    }
}

enum StackBuilder {

    // Parent edges come from two sources with different authority:
    //  - a PR's base branch is what GitHub will actually merge into, so it wins
    //    whenever a PR exists (it also survives rebases, which break ancestry);
    //  - for branches with no PR, the closest local ancestor branch is inferred
    //    from the commit graph.
    static func build(worktrees: [Worktree], pullRequests: [PullRequest]) -> (stacks: [Stack], merged: [Worktree]) {
        let merged = worktrees.filter(\.merged)
        let live = worktrees.filter { !$0.merged }

        let prByHead = Dictionary(pullRequests.map { ($0.headRef, $0) }, uniquingKeysWith: { a, _ in a })
        let wtByBranch = Dictionary(live.map { ($0.branch, $0) }, uniquingKeysWith: { a, _ in a })

        // Every ref that deserves a row: local branches plus the head of every
        // open PR (which pulls the ghosts in).
        let refs = Set(live.map(\.branch)).union(prByHead.keys)

        var parentOf: [String: String] = [:]
        for ref in refs {
            if let pr = prByHead[ref] {
                parentOf[ref] = pr.baseRef
            } else if let wt = wtByBranch[ref] {
                parentOf[ref] = inferredParent(of: wt, among: live) ?? Config.trunkRef.shortRef
            }
        }

        // A parent nobody has a row for is a trunk (main, minor, a release
        // branch…), so it becomes the head of its own stack.
        var childrenOf: [String: [String]] = [:]
        var trunks = Set<String>()
        for ref in refs {
            guard let parent = parentOf[ref] else { continue }
            childrenOf[parent, default: []].append(ref)
            if !refs.contains(parent) { trunks.insert(parent) }
        }

        func node(_ ref: String, visiting: Set<String>) -> StackNode {
            var seen = visiting
            seen.insert(ref)
            let kids = (childrenOf[ref] ?? [])
                // A PR base cycle would otherwise recurse forever.
                .filter { !seen.contains($0) }
                .map { node($0, visiting: seen) }
                // Largest subtree first: it becomes the flat mainline, so the
                // longest chain is the one that reads without indentation.
                .sorted { ($0.subtreeCount, $1.ref) > ($1.subtreeCount, $0.ref) }
            return StackNode(ref: ref, worktree: wtByBranch[ref], pr: prByHead[ref], children: kids)
        }

        let stacks = trunks
            .flatMap { trunk in
                (childrenOf[trunk] ?? []).map { Stack(trunk: trunk, root: node($0, visiting: [trunk])) }
            }
            // Most recent PR activity first — that's the stack you're working on.
            // Ties (stacks with no PRs at all) fall back to the branch name so
            // the order doesn't shuffle between refreshes.
            .sorted { lhs, rhs in
                let l = latestActivity(lhs.root) ?? .distantPast
                let r = latestActivity(rhs.root) ?? .distantPast
                if l != r { return l > r }
                return lhs.root.ref < rhs.root.ref
            }

        return (stacks, merged.sorted { $0.branch < $1.branch })
    }

    private static func latestActivity(_ node: StackNode) -> Date? {
        ([node.pr?.updatedAt] + node.children.map(latestActivity)).compactMap { $0 }.max()
    }

    // The candidate whose tip is already contained in this branch and which
    // itself sits highest above the trunk — i.e. the nearest ancestor branch.
    private static func inferredParent(of wt: Worktree, among candidates: [Worktree]) -> String? {
        candidates
            .filter { $0.branch != wt.branch && $0.commitsAboveTrunk > 0 && wt.commitsAboveTrunk > $0.commitsAboveTrunk }
            .filter { wt.containedTips.contains($0.tip) }
            .max { $0.commitsAboveTrunk < $1.commitsAboveTrunk }?
            .branch
    }
}

extension String {
    // "origin/main" -> "main", so a PR base ("main") and the trunk ref agree.
    var shortRef: String {
        hasPrefix("origin/") ? String(dropFirst("origin/".count)) : self
    }
}

// MARK: - Layout

// Rendering rule, driven by the 400pt-wide menu: the mainline is flat however
// deep it goes, a fork gets exactly one level of indent, and a fork inside a
// fork becomes a drill-in button instead of a third indent level.
struct ForkBlock: Identifiable {
    let parentLeaf: String
    var chain: [StackNode]
    var deeper: [StackNode]

    var id: String { parentLeaf + "→" + (chain.first?.ref ?? "") }
}

struct StackLayout {
    var mainline: [StackNode] = []
    var forks: [ForkBlock] = []

    init(root: StackNode) {
        var cursor: StackNode? = root
        var pending: [(parent: String, node: StackNode)] = []
        while let node = cursor {
            mainline.append(node)
            for fork in node.children.dropFirst() {
                pending.append((node.leaf, fork))
            }
            cursor = node.children.first
        }
        forks = pending.map { entry in
            var chain: [StackNode] = []
            var deeper: [StackNode] = []
            var cursor: StackNode? = entry.node
            while let node = cursor {
                chain.append(node)
                deeper.append(contentsOf: node.children.dropFirst())
                cursor = node.children.first
            }
            return ForkBlock(parentLeaf: entry.parent, chain: chain, deeper: deeper)
        }
    }
}
