import SwiftUI

enum Mode: Equatable {
    case list
    case create(base: String?) // nil => latest origin/main
    case addExisting(branch: String?) // non-nil => prefilled from a ghost row
    case confirmDelete(Worktree)
    // A subtree opened from a "N more branches below" button, so arbitrarily
    // deep forks stay reachable without ever indenting past one level.
    case subStack(ref: String)
}

struct MenuView: View {
    @EnvironmentObject var store: Store
    @State private var mode: Mode = .list
    @State private var expandedRef: String? // accordion: at most one row expanded
    @State private var collapsedStacks: Set<String> = []
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsKeys.featureAddExisting) private var featureAddExisting = true
    @AppStorage(SettingsKeys.featureOpenInStudio) private var featureStudio = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let banner = store.banner, mode == .list {
                Divider()
                BannerView(banner: banner) { store.banner = nil }
            }
            if let error = store.prError, mode == .list {
                Divider()
                PRErrorBar(message: error)
            }
            Divider()
            footer
        }
        .frame(width: 420)
        .background(WindowClamp())
        .onAppear {
            store.banner = nil
            mode = .list
            expandedRef = nil
            store.startPolling()
            Task { await store.refreshOnOpen() }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Stacks")
                .font(.headline)
            if store.isLoading || store.isLoadingPRs {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 2)
            }
            if store.attentionCount > 0 {
                Text("\(store.attentionCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange))
                    .help("\(store.attentionCount) item\(store.attentionCount == 1 ? "" : "s") need attention (CI failure, conflict, or unresolved review)")
            }
            Spacer()
            Text(freshness)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if featureStudio {
                AppIconButton(icon: AppIcons.studio, fallbackIcon: "hammer",
                              help: "Open main repo in Android Studio") {
                    Task { await store.openMainRepo() }
                }
            }
            Button {
                Task { await store.refreshEverything() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(HoverBackgroundButtonStyle())
            .disabled(store.isLoading || store.isLoadingPRs)
            .help("Fetch origin/main and re-read git + PR state")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // PR data is polled every 30 minutes, so the age of it matters more than
    // with the purely local git state.
    private var freshness: String {
        guard let at = store.prFetchedAt else { return "PRs not fetched" }
        let minutes = Int(Date().timeIntervalSince(at) / 60)
        if minutes < 1 { return "PRs just now" }
        if minutes < 60 { return "PRs \(minutes)m ago" }
        return "PRs \(minutes / 60)h ago"
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .list:
            StackListView(
                collapsedStacks: $collapsedStacks,
                expandedRef: $expandedRef,
                onBranchFrom: { mode = .create(base: $0.branch) },
                onDelete: { mode = .confirmDelete($0) },
                onAddWorktree: { mode = .addExisting(branch: $0) },
                onDrillIn: { mode = .subStack(ref: $0.ref) }
            )
        case .create(let base):
            CreateForm(base: base) { mode = .list }
        case .addExisting(let branch):
            AddExistingForm(prefill: branch) { mode = .list }
        case .confirmDelete(let wt):
            ConfirmDeleteView(wt: wt) { mode = .list }
        case .subStack(let ref):
            SubStackView(
                ref: ref,
                expandedRef: $expandedRef,
                onBack: { mode = .list },
                onBranchFrom: { mode = .create(base: $0.branch) },
                onDelete: { mode = .confirmDelete($0) },
                onAddWorktree: { mode = .addExisting(branch: $0) },
                onDrillIn: { mode = .subStack(ref: $0.ref) }
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                store.banner = nil
                mode = .create(base: nil)
            } label: {
                Label("New", systemImage: "plus")
            }
            if featureAddExisting {
                Button("Add Existing…") {
                    store.banner = nil
                    mode = .addExisting(branch: nil)
                }
            }
            Spacer()
            Button {
                // Settings is a regular window; bring the (accessory) app
                // forward or it opens behind whatever is focused.
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(HoverBackgroundButtonStyle())
            .help("Settings")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Drilled-in subtree

struct SubStackView: View {
    let ref: String
    @Binding var expandedRef: String?
    let onBack: () -> Void
    let onBranchFrom: (Worktree) -> Void
    let onDelete: (Worktree) -> Void
    let onAddWorktree: (String) -> Void
    let onDrillIn: (StackNode) -> Void

    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.caption2.weight(.semibold))
                    Text("All stacks")
                        .font(.caption)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let node = node {
                Text(node.ref)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                ScrollView {
                    ChainView(
                        root: node,
                        expandedRef: $expandedRef,
                        onBranchFrom: onBranchFrom,
                        onDelete: onDelete,
                        onAddWorktree: onAddWorktree,
                        onDrillIn: onDrillIn
                    )
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .frame(height: min(CGFloat(node.subtreeCount) * 46 + 12, 11 * 46))
            } else {
                Text("That branch is no longer in the stack.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
    }

    private var node: StackNode? {
        for stack in store.stacks {
            if let found = Self.find(ref, in: stack.root) { return found }
        }
        return nil
    }

    private static func find(_ ref: String, in node: StackNode) -> StackNode? {
        if node.ref == ref { return node }
        for child in node.children {
            if let found = find(ref, in: child) { return found }
        }
        return nil
    }
}

// Shown instead of failing silently: without PR data the view degrades to a
// plain git tree, and the reason (no gh, not logged in, offline) matters.
struct PRErrorBar: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text("PR data unavailable — \(message)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

// Row buttons for external apps, using the installed app's real icon
// (SF Symbols has no Android/cmux glyphs); fall back to a symbol if missing.
@MainActor
enum AppIcons {
    static let studio: NSImage? = {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.android.studio")
            ?? URL(fileURLWithPath: "/Applications/\(Config.studioApp).app")
        return icon(forAppAt: url)
    }()

    // Icon for whichever terminal app is selected in Settings.
    static func terminal(named name: String) -> NSImage? {
        if let cached = terminalCache[name] { return cached }
        let bundleID = TerminalApps.known.first { $0.name == name }?.bundleID
        let url = bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            ?? URL(fileURLWithPath: "/Applications/\(name).app")
        let icon = icon(forAppAt: url)
        terminalCache[name] = icon
        return icon
    }

    private static var terminalCache: [String: NSImage?] = [:]

    private static func icon(forAppAt url: URL) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 17, height: 17)
        return icon
    }
}

struct AppIconButton: View {
    let icon: NSImage?
    let fallbackIcon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let icon {
                Image(nsImage: icon)
                    .frame(width: 22, height: 20)
            } else {
                Image(systemName: fallbackIcon)
                    .frame(width: 22, height: 20)
            }
        }
        .buttonStyle(HoverBackgroundButtonStyle())
        .help(help)
    }
}


// MARK: - Create

struct CreateForm: View {
    let initialBase: String? // nil => Config.defaultBase
    var onDone: () -> Void

    init(base: String?, onDone: @escaping () -> Void) {
        self.initialBase = base
        self.onDone = onDone
        _base = State(initialValue: base ?? Config.defaultBase)
    }

    @EnvironmentObject var store: Store
    @State private var name = ""
    @State private var base: String
    @State private var pickingBase = false
    @State private var submitting = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Worktree")
                .font(.headline)
            HStack(spacing: 0) {
                Text(Config.branchPrefix)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                TextField("branch-name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { submit() }
                    .disabled(submitting)
            }
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

            BasePicker(
                base: $base,
                expanded: $pickingBase,
                branches: store.baseBranches,
                loading: store.isLoadingBranches
            )
            .disabled(submitting)

            Text(base.hasPrefix("origin/")
                ? "Based on the latest \(base) (fetched)"
                : "Based on \(base) (local tip, no fetch)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                ErrorText(error)
            }
            HStack {
                Spacer()
                Button("Cancel") { onDone() }
                    .disabled(submitting)
                Button(submitting ? "Creating…" : "Create") { submit() }
                    // While the branch search is open, Return belongs to it.
                    .keyboardShortcut(pickingBase ? nil : .defaultAction)
                    .disabled(submitting || trimmedName.isEmpty)
            }
        }
        .padding(12)
        .onAppear {
            if name.isEmpty, let folders = baseFolders {
                name = folders
            }
            focused = true
            Task { await store.loadBaseBranches() }
        }
    }

    // Folder portion of the base branch (prefix stripped, last segment dropped),
    // pre-filled so worktrees created from a foldered branch land in the same folder.
    private var baseFolders: String? {
        guard var base = initialBase else { return nil }
        if base.hasPrefix(Config.branchPrefix) {
            base = String(base.dropFirst(Config.branchPrefix.count))
        }
        guard let lastSlash = base.lastIndex(of: "/") else { return nil }
        return String(base[...lastSlash])
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedName.isEmpty, !submitting else { return }
        submitting = true
        error = nil
        Task {
            let outcome = await store.create(name: trimmedName, base: base)
            submitting = false
            if outcome.ok {
                onDone()
            } else {
                error = outcome.message ?? "create failed"
            }
        }
    }
}

// Base-ref chooser. The repo has ~1000 remote branches, so this is a search box
// over the branch list rather than a Picker menu. Free text is accepted too, so
// an origin branch that hasn't been fetched yet can still be used as the base.
struct BasePicker: View {
    @Binding var base: String
    @Binding var expanded: Bool
    let branches: [String]
    let loading: Bool

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private static let visibleRows = 7
    private static let rowHeight: CGFloat = 21

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Base")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    if expanded {
                        expanded = false
                    } else {
                        query = ""
                        expanded = true
                        searchFocused = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(base)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                }
                .controlSize(.small)
                .help("Choose the branch to create this worktree from")
                Spacer(minLength: 0)
            }

            if expanded {
                TextField("filter branches…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = candidates.first { choose(first) }
                    }
                results
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        let items = candidates
        if items.isEmpty {
            Text(loading ? "Loading branches…" : "No branches found.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if items.count <= Self.visibleRows {
            rows(items)
        } else {
            ScrollView {
                rows(items)
            }
            .frame(height: CGFloat(Self.visibleRows) * Self.rowHeight)
        }
    }

    private func rows(_ items: [String]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { index, branch in
                BranchRow(
                    name: branch,
                    selected: branch == base,
                    isReturnTarget: index == 0,
                    asTyped: branch == trimmedQuery && !branches.contains(branch)
                ) {
                    choose(branch)
                }
            }
        }
    }

    private func choose(_ branch: String) {
        base = branch
        expanded = false
        query = ""
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Matches ranked so the most literal one wins the Return key. A query that
    // matches nothing (or nothing exactly) is offered as-is at the end.
    private var candidates: [String] {
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty else { return Array(branches.prefix(400)) }
        let ranked = branches
            .filter { $0.lowercased().contains(q) }
            .map { (rank: rank($0, query: q), name: $0) }
            .sorted { ($0.rank, $0.name) < ($1.rank, $1.name) }
            .map(\.name)
            .prefix(400)
        let exact = ranked.contains { $0.lowercased() == q }
        return exact ? Array(ranked) : Array(ranked) + [trimmedQuery]
    }

    private func rank(_ branch: String, query: String) -> Int {
        let lower = branch.lowercased()
        let short = lower.hasPrefix("origin/") ? String(lower.dropFirst("origin/".count)) : lower
        if lower == query || short == query { return 0 }
        if short.hasPrefix(query) { return 1 }
        if lower.hasPrefix(query) { return 2 }
        return 3
    }
}

private struct BranchRow: View {
    let name: String
    let selected: Bool
    let isReturnTarget: Bool
    let asTyped: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.caption2)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(asTyped ? "Use “\(name)” as typed" : name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if isReturnTarget {
                    Image(systemName: "return")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? Color.primary.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onHover { hovering = $0 }
    }
}

// MARK: - Add existing

struct AddExistingForm: View {
    var onDone: () -> Void

    // Prefilled when reached from a ghost row, so checking out a missing link
    // in a stack is one click rather than retyping the branch.
    init(prefill: String? = nil, onDone: @escaping () -> Void) {
        self.onDone = onDone
        _branch = State(initialValue: prefill ?? "")
    }

    @EnvironmentObject var store: Store
    @State private var branch: String
    @State private var submitting = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Existing Branch")
                .font(.headline)
            TextField("branch name (origin/ prefix optional)", text: $branch)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { submit() }
                .disabled(submitting)
            Text("Fetches origin, then checks the branch out in a new worktree.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                ErrorText(error)
            }
            HStack {
                Spacer()
                Button("Cancel") { onDone() }
                    .disabled(submitting)
                Button(submitting ? "Adding…" : "Add") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(submitting || trimmedBranch.isEmpty)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private var trimmedBranch: String {
        branch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedBranch.isEmpty, !submitting else { return }
        submitting = true
        error = nil
        Task {
            let outcome = await store.addExisting(branch: trimmedBranch)
            submitting = false
            if outcome.ok {
                onDone()
            } else {
                error = outcome.message ?? "add failed"
            }
        }
    }
}

// MARK: - Delete confirmation

struct ConfirmDeleteView: View {
    let wt: Worktree
    var onDone: () -> Void

    @EnvironmentObject var store: Store
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete \(wt.branch)?")
                .font(.headline)
            Text("Removes the worktree folder and deletes the branch.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if wt.dirty {
                Label("Has uncommitted changes — they will be lost.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if wt.unpushed > 0 {
                Label("\(wt.unpushed) commit\(wt.unpushed == 1 ? "" : "s") not pushed anywhere — will be lost.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let shipRun = wt.shipRunPath {
                Label("Ship run folder \(shipRun) is left behind — prune it manually once the work is done.",
                      systemImage: "shippingbox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { onDone() }
                    .disabled(submitting)
                Button(submitting ? "Deleting…" : "Delete", role: .destructive) {
                    submitting = true
                    Task {
                        await store.delete(wt)
                        submitting = false
                        onDone()
                    }
                }
                .disabled(submitting)
            }
        }
        .padding(12)
    }
}

// MARK: - Bits

struct BannerView: View {
    let banner: Store.Banner
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? Color.red : Color.green)
            Text(banner.text)
                .font(.caption)
                .lineLimit(6)
                .textSelection(.enabled)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(HoverBackgroundButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(6)
            .textSelection(.enabled)
    }
}

// MARK: - Custom Button Style

struct HoverBackgroundButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.15 : 0.08))
                    .opacity(hovering ? 1 : 0)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
