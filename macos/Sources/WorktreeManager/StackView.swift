import AppKit
import SwiftUI

// The stack list. Tokens (sizes, insets, colours) live in DesignSystem.swift;
// the rules behind them are in DESIGN.md.

// MARK: - List

struct StackListView: View {
    @EnvironmentObject var store: Store
    @Binding var collapsedStacks: Set<String>
    @Binding var expandedRef: String?
    let onBranchFrom: (Worktree) -> Void
    let onDelete: (Worktree) -> Void
    let onAddWorktree: (String) -> Void
    let onDrillIn: (StackNode) -> Void

    var body: some View {
        if store.stacks.isEmpty && store.mergedWorktrees.isEmpty {
            EmptyStateView(loaded: store.hasLoadedOnce)
        } else if estimatedHeight <= Metrics.maxListHeight {
            // A ScrollView inside a MenuBarExtra window collapses to its
            // minimum height, so it is only used once the list needs it.
            content
        } else {
            ScrollView { content }
                .frame(height: Metrics.maxListHeight)
        }
    }

    private var estimatedHeight: CGFloat {
        let sections = store.stacks.reduce(CGFloat(0)) { total, stack in
            let rows = collapsedStacks.contains(stack.id) ? 0 : stack.nodeCount
            return total + 22 + CGFloat(rows) * Metrics.rowHeight + (rows == 0 ? 0 : 6)
        }
        let merged = store.mergedWorktrees.isEmpty ? 0 : CGFloat(22)
        let gaps = CGFloat(max(0, store.stacks.count)) * Metrics.sectionGap
        return sections + merged + gaps + 16
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionGap) {
            ForEach(store.stacks) { stack in
                StackSection(
                    stack: stack,
                    collapsed: collapsedStacks.contains(stack.id),
                    onToggle: {
                        if collapsedStacks.contains(stack.id) {
                            collapsedStacks.remove(stack.id)
                        } else {
                            collapsedStacks.insert(stack.id)
                        }
                    },
                    expandedRef: $expandedRef,
                    onBranchFrom: onBranchFrom,
                    onDelete: onDelete,
                    onAddWorktree: onAddWorktree,
                    onDrillIn: onDrillIn
                )
            }
            if !store.mergedWorktrees.isEmpty {
                MergedSection(worktrees: store.mergedWorktrees)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 8)
    }
}

struct EmptyStateView: View {
    let loaded: Bool

    var body: some View {
        VStack(spacing: 6) {
            if loaded {
                Image(systemName: "tray")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No worktrees")
                    .font(Typo.sectionTitle)
                Text("Create one with New below.")
                    .font(Typo.meta)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

// MARK: - Stack section

// A stack is a section, not a card: the title sits on the panel and only the
// rows get a container. One less box than a bordered card, and it matches how
// macOS groups a list under a heading.
struct StackSection: View {
    let stack: Stack
    let collapsed: Bool
    let onToggle: () -> Void
    @Binding var expandedRef: String?
    let onBranchFrom: (Worktree) -> Void
    let onDelete: (Worktree) -> Void
    let onAddWorktree: (String) -> Void
    let onDrillIn: (StackNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            if !collapsed {
                ChainView(
                    root: stack.root,
                    expandedRef: $expandedRef,
                    onBranchFrom: onBranchFrom,
                    onDelete: onDelete,
                    onAddWorktree: onAddWorktree,
                    onDrillIn: onDrillIn
                )
                .stackGroup()
            }
        }
    }

    // Measured at the bottom of the stack, which is the only branch that
    // actually needs to pull the trunk — the rest inherit it up the chain.
    // Suppressed for stacks on some other base, because the count comes from
    // Config.trunkRef and would be measuring against the wrong branch.
    private var behindTrunk: Int {
        guard stack.trunk == Config.trunkRef.shortRef else { return 0 }
        return stack.root.worktree?.behindTrunk ?? 0
    }

    // Titled by the branch folder of the bottom of the stack — the one that
    // merges first — with its leaf kept alongside so the exact branch is still
    // readable when the folder alone is ambiguous.
    private var header: some View {
        SectionHeader(
            title: stack.title,
            subtitle: stack.title == stack.root.leaf ? nil : stack.root.leaf,
            expanded: !collapsed,
            onToggle: onToggle
        ) {
            HStack(spacing: 8) {
                // Collapsed, the dots stand in for the rows that are hidden, so
                // a folded stack still shows where the trouble is. Expanded,
                // the rows themselves say it and repeating it is just noise.
                if collapsed {
                    StackHealthStrip(stack: stack)
                }
                if behindTrunk > 0 {
                    Text("↓\(behindTrunk)")
                        .font(Typo.meta)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .help("The bottom of this stack is \(behindTrunk) commit\(behindTrunk == 1 ? "" : "s") behind \(stack.trunk)")
                }
                Text("\(stack.nodeCount) → \(stack.trunk)")
                    .font(Typo.meta)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .help("\(stack.prCount) PR\(stack.prCount == 1 ? "" : "s") · \(stack.nodeCount) branch\(stack.nodeCount == 1 ? "" : "es") onto \(stack.trunk)")
            }
        }
    }
}

// A row of CI dots, one per branch, bottom of the stack first — a sparkline of
// the stack's health while it's collapsed.
struct StackHealthStrip: View {
    let stack: Stack

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(states.prefix(12).enumerated()), id: \.offset) { _, state in
                Circle()
                    .fill(state.map(StackStyle.ciColor) ?? Color.secondary.opacity(0.3))
                    .frame(width: 5, height: 5)
            }
        }
    }

    private var states: [CIState?] {
        var out: [CIState?] = []
        func walk(_ node: StackNode) {
            out.append(node.pr?.ci)
            for child in node.children { walk(child) }
        }
        walk(stack.root)
        return out
    }
}

// MARK: - Chain

// The mainline renders flat however deep it goes — an 8-PR stack indented 8
// times would leave no room for a branch name in a 420pt menu. Forks get one
// level of indent; anything deeper becomes a drill-in button.
struct ChainView: View {
    let root: StackNode
    @Binding var expandedRef: String?
    let onBranchFrom: (Worktree) -> Void
    let onDelete: (Worktree) -> Void
    let onAddWorktree: (String) -> Void
    let onDrillIn: (StackNode) -> Void

    private var layout: StackLayout { StackLayout(root: root) }

    var body: some View {
        let chain = layout.mainline
        VStack(spacing: 0) {
            ForEach(Array(chain.enumerated()), id: \.element.id) { index, node in
                NodeRow(
                    node: node,
                    hasParent: index > 0,
                    hasChild: index < chain.count - 1,
                    expanded: expandedRef == node.ref,
                    onToggleExpand: { expandedRef = expandedRef == node.ref ? nil : node.ref },
                    onBranchFrom: onBranchFrom,
                    onDelete: onDelete,
                    onAddWorktree: onAddWorktree
                )
            }
            ForEach(layout.forks) { fork in
                ForkBlockView(
                    fork: fork,
                    expandedRef: $expandedRef,
                    onBranchFrom: onBranchFrom,
                    onDelete: onDelete,
                    onAddWorktree: onAddWorktree,
                    onDrillIn: onDrillIn
                )
            }
        }
    }
}

// A branch that isn't on the mainline. Labelled with its fork point rather than
// drawn with an elbow, which keeps it readable at this width and makes the
// branch point explicit instead of something you infer from indentation.
struct ForkBlockView: View {
    let fork: ForkBlock
    @Binding var expandedRef: String?
    let onBranchFrom: (Worktree) -> Void
    let onDelete: (Worktree) -> Void
    let onAddWorktree: (String) -> Void
    let onDrillIn: (StackNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .semibold))
                Text("off \(fork.parentLeaf)")
                    .font(Typo.meta)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tertiary)
            .padding(.leading, Metrics.rail)
            .padding(.top, 4)
            .padding(.bottom, 2)

            ForEach(Array(fork.chain.enumerated()), id: \.element.id) { index, node in
                NodeRow(
                    node: node,
                    hasParent: index > 0,
                    hasChild: index < fork.chain.count - 1,
                    expanded: expandedRef == node.ref,
                    onToggleExpand: { expandedRef = expandedRef == node.ref ? nil : node.ref },
                    onBranchFrom: onBranchFrom,
                    onDelete: onDelete,
                    onAddWorktree: onAddWorktree
                )
            }

            if !fork.deeper.isEmpty {
                // A third indent level would not fit, so the rest of the
                // subtree opens as its own view instead.
                Button {
                    if let first = fork.chain.first { onDrillIn(first) }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(fork.deeper.count) more branch\(fork.deeper.count == 1 ? "" : "es") below")
                            .font(Typo.meta)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.leading, Metrics.rail)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(StackStyle.rail)
                .frame(width: 1)
                .padding(.leading, 7)
        }
    }
}

// MARK: - Row

// One line per branch. The second line the old row had (PR number and badges
// under the name) doubled the height of every row for metadata that reads fine
// on the right-hand side of the same line.
struct NodeRow: View {
    let node: StackNode
    let hasParent: Bool
    let hasChild: Bool
    let expanded: Bool
    let onToggleExpand: () -> Void
    let onBranchFrom: (Worktree) -> Void
    let onDelete: (Worktree) -> Void
    let onAddWorktree: (String) -> Void

    @EnvironmentObject var store: Store
    @Environment(\.cmuxAvailable) private var cmuxAvailable
    @State private var hovering = false
    @AppStorage(SettingsKeys.featurePullLatest) private var featurePull = true
    @AppStorage(SettingsKeys.featureBranchFrom) private var featureBranchFrom = true
    @AppStorage(SettingsKeys.featureCopyPath) private var featureCopyPath = true
    @AppStorage(SettingsKeys.featureOpenInTerminal) private var featureTerminal = true
    @AppStorage(SettingsKeys.featureOpenInStudio) private var featureStudio = true
    @AppStorage(SettingsKeys.featureResolveConflicts) private var featureResolveConflicts = true
    @AppStorage(SettingsKeys.terminalApp) private var terminalApp = "Terminal"

    private var wt: Worktree? { node.worktree }
    private var busy: Bool { wt.map { store.busyPaths.contains($0.path) } ?? false }

    private var status: RowStatus {
        RowStatus(node: node, resolveEnabled: featureResolveConflicts && cmuxAvailable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleLine
                .frame(height: Metrics.rowHeight)
            if expanded {
                expandedDetail
                    .padding(.leading, Metrics.rail)
                    .padding(.bottom, 6)
            }
        }
        .padding(.horizontal, 6)
        .background(alignment: .topLeading) { rail.padding(.leading, 6) }
        .background(
            RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .fill(hovering || expanded ? StackStyle.rowHover : .clear)
                .padding(.horizontal, 3)
        )
        .onHover { hovering = $0 }
    }

    // Drawn as a background rather than an HStack child so it spans the row's
    // full height — as a child it would take its ideal height and stop short of
    // the next row's dot.
    private var rail: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(hasParent ? StackStyle.rail : .clear)
                .frame(width: 1, height: (Metrics.rowHeight - Metrics.dot) / 2)
            dot
            Rectangle()
                .fill(hasChild ? StackStyle.rail : .clear)
                .frame(width: 1)
        }
        .frame(width: Metrics.rail)
    }

    @ViewBuilder
    private var dot: some View {
        let ci = node.pr?.ci ?? CIState.none
        Circle()
            .fill(node.pr == nil ? Color.clear : StackStyle.ciColor(ci))
            .frame(width: Metrics.dot, height: Metrics.dot)
            .overlay(
                Circle().strokeBorder(
                    node.pr == nil ? Color.secondary.opacity(0.5) : .clear,
                    lineWidth: 1.2)
            )
            .help(dotHelp)
    }

    private var dotHelp: String {
        guard let pr = node.pr else { return "No pull request" }
        switch pr.ci {
        case .success: return "CI passing"
        case .failure: return "CI failing"
        case .pending: return "CI running"
        case .none: return "No CI checks reported"
        }
    }

    private var titleLine: some View {
        let status = self.status
        return HStack(spacing: 6) {
            Color.clear.frame(width: Metrics.rail - 6, height: 1)

            Text(node.leaf)
                .font(Typo.row)
                .foregroundStyle(StackStyle.nameColor(status.nameState))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(nameHelp)

            LocalStateMarks(status: status)

            // Not gated on hover like the other row actions: a conflict is
            // blocking work, so the way out of it stays on screen.
            if let wt, status.showsResolveChip {
                ResolveConflictButton(blockedByDirtyTree: status.blockedByDirtyTree) {
                    Task { await store.resolveConflicts(wt) }
                }
            }

            Spacer(minLength: 4)

            // Hover swaps the status glyphs for the actions; the PR number
            // keeps its column either way, so the link never moves or vanishes
            // under the pointer.
            if busy {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(height: 14)
            } else if hovering || expanded {
                rowActions
            } else {
                PRStatus(status: status)
            }

            PRNumber(pr: node.pr)
                .frame(width: Metrics.prColumn, alignment: .trailing)
        }
    }

    private var nameHelp: String {
        var parts = [node.ref]
        if let wt {
            if wt.conflicts { parts.append("Merge conflict in progress") }
            else if wt.dirty { parts.append("\(wt.dirtyCount) uncommitted change\(wt.dirtyCount == 1 ? "" : "s")") }
            parts.append(wt.path)
        } else {
            parts.append("Not checked out here")
        }
        if let title = node.pr?.title { parts.append(title) }
        return parts.joined(separator: "\n")
    }

    private var rowActions: some View {
        HStack(spacing: 0) {
            if let wt {
                if featureCopyPath {
                    MiniButton(icon: "doc.on.doc", help: "Copy worktree path") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(wt.path, forType: .string)
                        store.banner = Store.Banner(text: "Copied \(wt.path)", isError: false)
                    }
                }
                if featureTerminal {
                    MiniAppButton(icon: AppIcons.terminal(named: terminalApp), fallbackIcon: "terminal",
                                  help: terminalApp == TerminalApps.cmuxName
                                      ? "Open cmux tab here (reuses one already at this folder)"
                                      : "Open in \(terminalApp)") {
                        Task { await store.openInTerminal(wt) }
                    }
                }
                if featureStudio {
                    MiniAppButton(icon: AppIcons.studio, fallbackIcon: "hammer",
                                  help: "Open in Android Studio") {
                        Task { await store.open(wt) }
                    }
                }
                MiniButton(icon: expanded ? "chevron.up" : "ellipsis", help: "More actions") {
                    onToggleExpand()
                }
            } else {
                MiniButton(icon: "plus", help: "Add a worktree for this branch") {
                    onAddWorktree(node.ref)
                }
            }
        }
    }

    // Only opened on demand: the PR title and the destructive actions.
    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pr = node.pr {
                Text(pr.title)
                    .font(Typo.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("+\(pr.additions)").foregroundStyle(.green)
                        Text("−\(pr.deletions)").foregroundStyle(.red)
                    }
                    .monospacedDigit()
                    Text("into \(pr.baseRef.shortRef)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(Typo.meta)
            }
            if let wt {
                HStack(spacing: 6) {
                    if featurePull {
                        Button {
                            Task { await store.pull(wt) }
                        } label: {
                            Label("Pull main", systemImage: "arrow.down")
                        }
                        .disabled(busy || wt.conflicts || wt.behindTrunk == 0)
                        .help(wt.behindTrunk == 0
                              ? "Already up to date with \(Config.trunkRef)"
                              : "Merge in \(wt.behindTrunk) commit\(wt.behindTrunk == 1 ? "" : "s") from \(Config.trunkRef)")
                    }
                    if featureBranchFrom {
                        Button {
                            onBranchFrom(wt)
                        } label: {
                            Label("Stack on", systemImage: "plus")
                        }
                        .disabled(busy)
                        .help("New worktree branched off this one")
                    }
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        onDelete(wt)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(busy)
                    .help("Delete worktree and branch")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text("Not checked out here — add a worktree to work on it.")
                    .font(Typo.meta)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.trailing, 6)
        .padding(.top, 2)
    }
}

// MARK: - Row metadata

// Uncommitted and unpushed work, in the dirty colour the branch name already
// uses. Sits next to the name because it is a fact about the local branch, not
// about its PR.
struct LocalStateMarks: View {
    let status: RowStatus

    var body: some View {
        if status.dirtyCount > 0 || status.unpushed > 0 {
            HStack(spacing: 4) {
                if status.dirtyCount > 0 {
                    Text("\(status.dirtyCount)●")
                        .help("\(status.dirtyCount) uncommitted change\(status.dirtyCount == 1 ? "" : "s")")
                }
                if status.unpushed > 0 {
                    Text("↑\(status.unpushed)")
                        .help("\(status.unpushed) commit\(status.unpushed == 1 ? "" : "s") not pushed anywhere")
                }
            }
            .font(.system(size: 9))
            .monospacedDigit()
            .foregroundStyle(StackStyle.dirty)
            .fixedSize()
        }
    }
}

// Everything about the PR except its number: draft, conflicts, review, comments.
// Each item is either absent or exceptional — a healthy PR shows nothing here.
struct PRStatus: View {
    let status: RowStatus

    var body: some View {
        HStack(spacing: 6) {
            if status.isDraft {
                Text("Draft")
                    .font(Typo.meta)
                    .foregroundStyle(.tertiary)
            }
            if status.showsConflictWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .help("This PR conflicts with its base branch")
            }
            reviewBadge
            CommentIndicator(comments: status.comments)
            if let placeholder = status.placeholder {
                Text(placeholder)
                    .font(Typo.meta)
                    .foregroundStyle(.tertiary)
                    .help(status.nameState == .ghost
                          ? "This PR is a link in the stack but isn't checked out locally"
                          : "No pull request for this branch yet")
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var reviewBadge: some View {
        switch status.review {
        case .approved:
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .help("Approved")
        case .changesRequested:
            Image(systemName: "xmark.seal.fill")
                .font(.system(size: 11))
                .foregroundStyle(StackStyle.attention)
                .help("Changes requested")
        case .none:
            EmptyView()
        }
    }
}

// The click target for the PR itself, right-aligned into a fixed column so the
// numbers line up down the list.
struct PRNumber: View {
    let pr: PullRequest?
    @State private var hovering = false

    var body: some View {
        if let pr {
            Button {
                GitHubService.openPR(pr)
            } label: {
                Text("#\(String(pr.number))")
                    .font(Typo.meta)
                    .monospacedDigit()
                    .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Open PR #\(String(pr.number)) in your browser")
        }
    }
}

// Comment authors as avatars: with four bots posting size reports and reviews
// on every PR, a bare count says nothing — who is waiting on you does. Which
// case applies is decided in RowStatus; this only draws it.
struct CommentIndicator: View {
    let comments: RowStatus.Comments

    var body: some View {
        switch comments {
        case .unresolved(let threads, let people):
            HStack(spacing: 3) {
                HStack(spacing: -3) {
                    ForEach(people.prefix(2), id: \.login) { person in
                        AvatarView(person: person)
                    }
                }
                Text("\(threads)")
                    .font(Typo.metaEmphasis)
                    .monospacedDigit()
                    .foregroundStyle(StackStyle.attention)
            }
            .help(help(threads: threads, people: people))
        case .bubble:
            Image(systemName: "bubble.left")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help("A comment from someone else, with nothing unresolved")
        case .none:
            EmptyView()
        }
    }

    private func help(threads: Int, people: [Commenter]) -> String {
        var lines = ["\(threads) unresolved review thread\(threads == 1 ? "" : "s")"]
        for person in people {
            lines.append("\(person.login)\(person.isBot ? " (bot)" : "") — \(person.unresolved) unresolved")
        }
        return lines.joined(separator: "\n")
    }
}

struct AvatarView: View {
    let person: Commenter
    @ObservedObject private var cache = AvatarCache.shared

    var body: some View {
        // Circle for people, rounded square for apps — GitHub's own convention,
        // so a bot avatar reads as a bot without needing the tooltip.
        let shape: AnyShape = person.isBot
            ? AnyShape(RoundedRectangle(cornerRadius: 3))
            : AnyShape(Circle())
        Group {
            if let image = cache.image(for: person.avatarURL) {
                Image(nsImage: image).resizable()
            } else {
                Rectangle().fill(Color.primary.opacity(0.15))
            }
        }
        .frame(width: 13, height: 13)
        .clipShape(shape)
        // Ring in the window colour so overlapping avatars stay separable.
        .overlay(shape.stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
        .task { cache.load(person.avatarURL) }
    }
}

// MARK: - Merged section

struct MergedSection: View {
    let worktrees: [Worktree]
    @EnvironmentObject var store: Store
    @State private var expanded = false
    @State private var confirming = false

    private var prunable: [Worktree] { worktrees.filter { !$0.dirty && $0.unpushed == 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionHeader(
                title: "Merged",
                subtitle: "\(worktrees.count) branch\(worktrees.count == 1 ? "" : "es") already in \(Config.trunkRef.shortRef)",
                expanded: expanded,
                onToggle: { expanded.toggle() }
            ) {
                EmptyView()
            }

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(worktrees) { wt in
                        HStack(spacing: 6) {
                            Text(wt.branch)
                                .font(Typo.meta)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            if wt.dirty || wt.unpushed > 0 {
                                Text(wt.dirty ? "uncommitted" : "unpushed")
                                    .font(.system(size: 10))
                                    .foregroundStyle(StackStyle.dirty)
                                    .help("Kept out of the prune — it still has local work")
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 20)
                    }

                    if confirming {
                        HStack(spacing: 6) {
                            Text("Delete \(prunable.count) worktree\(prunable.count == 1 ? "" : "s") and branch\(prunable.count == 1 ? "" : "es")?")
                                .font(Typo.meta)
                            Spacer(minLength: 0)
                            Button("Cancel") { confirming = false }
                            Button("Prune", role: .destructive) {
                                let targets = prunable
                                confirming = false
                                Task { await store.pruneMerged(targets) }
                            }
                        }
                        .controlSize(.small)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    } else if !prunable.isEmpty {
                        Button {
                            confirming = true
                        } label: {
                            Label("Prune \(prunable.count) merged", systemImage: "trash")
                                .font(Typo.meta)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .stackGroup()
            }
        }
    }
}
