import AppKit
import SwiftUI

// Colour vocabulary for the whole stack view, in one place so the legend in
// Settings can't drift from what the rows actually draw.
enum StackStyle {
    static let rail = Color.primary.opacity(0.18)
    static let dirty = Color(red: 0.85, green: 0.62, blue: 0.10)
    static let ciPending = Color(red: 0.90, green: 0.75, blue: 0.20)

    // The dot carries CI state and nothing else, so a red dot always means the
    // build is broken — merge conflicts get their own chip instead.
    static func ciColor(_ state: CIState) -> Color {
        switch state {
        case .success: return .green
        case .failure: return .red
        case .pending: return ciPending
        case .none: return Color.secondary.opacity(0.5)
        }
    }

    // Local working-tree state rides on the branch name's colour.
    static func nameColor(_ wt: Worktree?) -> Color {
        guard let wt else { return .secondary }
        if wt.conflicts { return .red }
        if wt.dirty { return dirty }
        return .primary
    }
}

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
            Text(store.hasLoadedOnce ? "No worktrees yet." : "Loading…")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else if estimatedRows <= 11 {
            // A ScrollView inside a MenuBarExtra window collapses to its
            // minimum height, so it is only used once the list needs it.
            content
        } else {
            ScrollView { content }
                .frame(height: 11 * 46)
        }
    }

    private var estimatedRows: Int {
        store.stacks.reduce(0) { total, stack in
            total + 1 + (collapsedStacks.contains(stack.id) ? 0 : stack.nodeCount)
        } + (store.mergedWorktrees.isEmpty ? 0 : 1)
    }

    private var content: some View {
        VStack(spacing: 6) {
            ForEach(store.stacks) { stack in
                StackCard(
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
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }
}

// MARK: - Stack card

struct StackCard: View {
    let stack: Stack
    let collapsed: Bool
    let onToggle: () -> Void
    @Binding var expandedRef: String?
    let onBranchFrom: (Worktree) -> Void
    let onDelete: (Worktree) -> Void
    let onAddWorktree: (String) -> Void
    let onDrillIn: (StackNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                .padding(.bottom, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
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
        Button(action: onToggle) {
            HStack(spacing: 5) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 9)
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(stack.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if stack.title != stack.root.leaf {
                    Text(stack.root.leaf)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if collapsed {
                    // The dots stand in for the rows that are hidden, so a
                    // collapsed stack still shows where the trouble is.
                    StackHealthStrip(stack: stack)
                }
                if behindTrunk > 0 {
                    Text("↓\(behindTrunk)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help("The bottom of this stack is \(behindTrunk) commit\(behindTrunk == 1 ? "" : "s") behind \(stack.trunk)")
                }
                Text("\(stack.nodeCount) → \(stack.trunk)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("\(stack.prCount) PR\(stack.prCount == 1 ? "" : "s") · \(stack.nodeCount) branch\(stack.nodeCount == 1 ? "" : "es") onto \(stack.trunk)")
                if stack.needsAttention {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Something in this stack needs attention")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    var indent: CGFloat = 0

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
        .padding(.leading, indent)
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
                Text("branched off")
                    .font(.caption2)
                Text(fork.parentLeaf)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 10)
            .padding(.top, 3)
            .padding(.bottom, 1)

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
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 9))
                        Text("\(fork.deeper.count) more branch\(fork.deeper.count == 1 ? "" : "es") below")
                            .font(.caption2)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.leading, 10)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(StackStyle.rail)
                .frame(width: 1)
                .padding(.leading, 6)
        }
    }
}

// MARK: - Row

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
    @State private var hovering = false
    @AppStorage(SettingsKeys.featurePullLatest) private var featurePull = true
    @AppStorage(SettingsKeys.featureBranchFrom) private var featureBranchFrom = true
    @AppStorage(SettingsKeys.featureCopyPath) private var featureCopyPath = true
    @AppStorage(SettingsKeys.featureOpenInTerminal) private var featureTerminal = true
    @AppStorage(SettingsKeys.featureOpenInStudio) private var featureStudio = true
    @AppStorage(SettingsKeys.terminalApp) private var terminalApp = "Terminal"

    private var wt: Worktree? { node.worktree }
    private var busy: Bool { wt.map { store.busyPaths.contains($0.path) } ?? false }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Placeholder only: the rail is drawn as a background so it spans
            // the row's full height. As an HStack child it would take its ideal
            // height instead and stop short of the next row's dot.
            Color.clear.frame(width: 16, height: 1)
            VStack(alignment: .leading, spacing: 1) {
                titleLine
                PRFooter(node: node)
                if expanded { expandedDetail }
            }
            .padding(.vertical, 4)
        }
        .padding(.trailing, 6)
        .background(alignment: .topLeading) { rail }
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(hovering || expanded ? 0.05 : 0))
                .padding(.leading, 18)
        )
        .onHover { hovering = $0 }
    }

    private var rail: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(hasParent ? StackStyle.rail : .clear)
                .frame(width: 1, height: 9)
            dot
            Rectangle()
                .fill(hasChild ? StackStyle.rail : .clear)
                .frame(width: 1)
        }
        .frame(width: 16)
    }

    @ViewBuilder
    private var dot: some View {
        let ci = node.pr?.ci ?? CIState.none
        Circle()
            .fill(node.pr == nil ? Color.clear : StackStyle.ciColor(ci))
            .frame(width: 8, height: 8)
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
        HStack(spacing: 5) {
            Text(node.leaf)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(StackStyle.nameColor(wt))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(nameHelp)

            if node.isGhost {
                Text("no worktree")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .help("This PR is a link in the stack but isn't checked out locally")
            }

            Spacer(minLength: 4)

            if busy {
                ProgressView().controlSize(.small)
            } else if hovering || expanded {
                rowActions
            }
        }
    }

    private var nameHelp: String {
        var parts = [node.ref]
        if let wt {
            if wt.conflicts { parts.append("Merge conflict in progress") }
            else if wt.dirty { parts.append("\(wt.dirtyCount) uncommitted change\(wt.dirtyCount == 1 ? "" : "s")") }
            parts.append(wt.path)
        }
        if let title = node.pr?.title { parts.append(title) }
        return parts.joined(separator: "\n")
    }

    private var rowActions: some View {
        HStack(spacing: 1) {
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
                MiniButton(icon: "plus.circle", help: "Add a worktree for this branch") {
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("+\(pr.additions)")
                        .foregroundStyle(.green)
                    Text("−\(pr.deletions)")
                        .foregroundStyle(.red)
                    Text("into \(pr.baseRef.shortRef)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 10, design: .monospaced))
            }
            if let wt {
                HStack(spacing: 6) {
                    if featurePull {
                        Button {
                            Task { await store.pull(wt) }
                        } label: {
                            Label("Pull main", systemImage: "arrow.down.circle")
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
                            Label("Stack on", systemImage: "plus.rectangle.on.rectangle")
                        }
                        .disabled(busy)
                        .help("New worktree branched off this one")
                    }
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        onDelete(wt)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .disabled(busy)
                    .help("Delete worktree and branch")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text("Not checked out here — add a worktree to work on it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 3)
        .padding(.bottom, 2)
    }
}

// MARK: - PR footer

struct PRFooter: View {
    let node: StackNode

    var body: some View {
        HStack(spacing: 6) {
            if let pr = node.pr {
                prNumber(pr)
                if pr.isDraft {
                    Text("draft")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                if pr.mergeable == .conflicting {
                    Label("conflicts", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .help("This PR conflicts with its base branch")
                }
                reviewBadge(pr)
                CommentIndicator(pr: pr)
            } else {
                Text("no PR")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            Spacer(minLength: 0)
            localState
        }
    }

    private func prNumber(_ pr: PullRequest) -> some View {
        Button {
            GitHubService.openPR(pr)
        } label: {
            HStack(spacing: 2) {
                Text("#\(String(pr.number))")
                    .font(.system(size: 10, design: .monospaced))
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open PR #\(String(pr.number)) in your browser")
    }

    @ViewBuilder
    private func reviewBadge(_ pr: PullRequest) -> some View {
        // REVIEW_REQUIRED is the default on almost every open PR, so only the
        // states that actually changed something are worth a badge.
        switch pr.review {
        case .approved:
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
                .help("Approved")
        case .changesRequested:
            Image(systemName: "xmark.seal.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .help("Changes requested")
        case .reviewRequired, .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var localState: some View {
        if let wt = node.worktree {
            HStack(spacing: 5) {
                if wt.dirty {
                    Text("\(wt.dirtyCount)●")
                        .foregroundStyle(StackStyle.dirty)
                        .help("\(wt.dirtyCount) uncommitted change\(wt.dirtyCount == 1 ? "" : "s")")
                }
                if wt.unpushed > 0 {
                    Text("↑\(wt.unpushed)")
                        .foregroundStyle(StackStyle.dirty)
                        .help("\(wt.unpushed) commit\(wt.unpushed == 1 ? "" : "s") not pushed anywhere")
                }
                // How far behind the trunk a branch is deliberately isn't here:
                // every branch in a stack is behind by roughly the same amount,
                // so per-row it was the same number repeated down the card. It
                // lives on the stack header instead.
            }
            .font(.system(size: 10, design: .monospaced))
        }
    }
}

// Comment authors as avatars: with four bots posting size reports and reviews
// on every PR, a bare count says nothing — who is waiting on you does.
struct CommentIndicator: View {
    let pr: PullRequest

    // Four bots comment on every single PR here, so showing the indicator
    // whenever `participants` is non-empty lit up all 22 rows and told you
    // nothing. Only unresolved threads (whoever opened them, bot or human) and
    // real human comments qualify.
    private var shown: [Commenter] {
        let unresolved = pr.participants.filter { $0.unresolved > 0 }
        if !unresolved.isEmpty { return unresolved }
        return pr.participants.filter { !$0.isBot && !$0.isViewer && $0.comments > 0 }
    }

    var body: some View {
        let people = shown
        if !people.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: pr.unresolvedThreads > 0 ? "bubble.left.fill" : "bubble.left")
                    .font(.system(size: 9))
                    .foregroundStyle(pr.unresolvedThreads > 0 ? .orange : .secondary)
                HStack(spacing: -3) {
                    ForEach(people.prefix(3), id: \.login) { person in
                        AvatarView(person: person)
                    }
                }
                if people.count > 3 {
                    Text("+\(people.count - 3)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                if pr.unresolvedThreads > 0 {
                    Text("\(pr.unresolvedThreads)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }
            .help(helpText)
        }
    }

    private var helpText: String {
        var lines: [String] = []
        if pr.unresolvedThreads > 0 {
            lines.append("\(pr.unresolvedThreads) unresolved review thread\(pr.unresolvedThreads == 1 ? "" : "s")")
        } else {
            lines.append("No unresolved review threads")
        }
        for person in pr.participants {
            var detail = "\(person.login)\(person.isBot ? " (bot)" : "")"
            var counts: [String] = []
            if person.unresolved > 0 { counts.append("\(person.unresolved) unresolved") }
            if person.comments > 0 { counts.append("\(person.comments) comment\(person.comments == 1 ? "" : "s")") }
            if !counts.isEmpty { detail += " — " + counts.joined(separator: ", ") }
            lines.append(detail)
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
        .frame(width: 14, height: 14)
        .clipShape(shape)
        // Ring in the window colour so overlapping avatars stay separable.
        .overlay(shape.stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
        .opacity(person.unresolved > 0 ? 1 : 0.75)
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
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 9)
                    Image(systemName: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Merged")
                        .font(.caption.weight(.semibold))
                    Text("\(worktrees.count) branch\(worktrees.count == 1 ? "" : "es") already in \(Config.trunkRef.shortRef)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(worktrees) { wt in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(wt.branch)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        if wt.dirty || wt.unpushed > 0 {
                            Text(wt.dirty ? "uncommitted" : "unpushed")
                                .font(.system(size: 9))
                                .foregroundStyle(StackStyle.dirty)
                                .help("Kept out of the prune — it still has local work")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                }

                if confirming {
                    HStack(spacing: 6) {
                        Text("Delete \(prunable.count) worktree\(prunable.count == 1 ? "" : "s") and branch\(prunable.count == 1 ? "" : "es")?")
                            .font(.caption2)
                        Spacer(minLength: 0)
                        Button("Cancel") { confirming = false }
                        Button("Prune", role: .destructive) {
                            let targets = prunable
                            confirming = false
                            Task { await store.pruneMerged(targets) }
                        }
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                } else if !prunable.isEmpty {
                    Button {
                        confirming = true
                    } label: {
                        Label("Prune \(prunable.count) merged", systemImage: "trash")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - Buttons

struct MiniButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .frame(width: 18, height: 16)
        }
        .buttonStyle(HoverBackgroundButtonStyle())
        .help(help)
    }
}

struct MiniAppButton: View {
    let icon: NSImage?
    let fallbackIcon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 13, height: 13)
                } else {
                    Image(systemName: fallbackIcon).font(.system(size: 10))
                }
            }
            .frame(width: 18, height: 16)
        }
        .buttonStyle(HoverBackgroundButtonStyle())
        .help(help)
    }
}
