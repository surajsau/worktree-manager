import AppKit
import SwiftUI

@main
enum Entry {
    static func main() async {
        // Debug/verification hook: print the worktree list and exit, no UI.
        if CommandLine.arguments.contains("--list") {
            for wt in await GitService.listWorktrees() {
                let flags = [
                    wt.dirty ? "dirty" : "clean",
                    wt.conflicts ? "CONFLICT" : nil,
                    wt.behind > 0 ? "↓\(wt.behind)" : nil,
                    wt.ahead > 0 ? "↑\(wt.ahead)" : nil,
                    wt.unpushed > 0 ? "\(wt.unpushed) unpushed" : nil,
                    wt.merged ? "MERGED into \(Config.trunkRef.shortRef)" : nil,
                ].compactMap { $0 }.joined(separator: ", ")
                print("\(wt.branch)  [\(flags)]  \(wt.path)")
            }
            return
        }
        // Debug/verification hook: print the stack tree exactly as the menu
        // would group it (mainline flat, forks labelled) and exit, no UI.
        if CommandLine.arguments.contains("--stacks") {
            let worktrees = await GitService.listWorktrees()
            var prs: [PullRequest] = []
            switch await GitHubService.fetchPullRequests() {
            case .success(let fetched): prs = fetched
            case .failure(let failure): print("PR fetch failed: \(failure.message)")
            }
            let tree = StackBuilder.build(worktrees: worktrees, pullRequests: prs)
            for stack in tree.stacks {
                let leaf = stack.title == stack.root.leaf ? "" : " (\(stack.root.leaf))"
                print("\n■ \(stack.title)\(leaf) → \(stack.trunk) — \(stack.prCount) PRs, \(stack.nodeCount) branches\(stack.needsAttention ? "  [needs attention]" : "")")
                printChain(stack.root, indent: 1)
            }
            if !tree.merged.isEmpty {
                print("\n■ Merged into \(Config.trunkRef.shortRef) — prunable")
                for wt in tree.merged {
                    print("    ✓ \(wt.branch)\(wt.dirty ? "  [uncommitted]" : "")\(wt.unpushed > 0 ? "  [unpushed]" : "")")
                }
            }
            return
        }
        // Debug/verification hook: run the tree/layout logic against a branching
        // stack. Real data is mostly linear chains, so the fork and drill-in
        // paths would otherwise go untested.
        if CommandLine.arguments.contains("--stacks-selftest") {
            let tree = StackBuilder.build(worktrees: [], pullRequests: SampleData.forkedStackPullRequests)
            print("stacks: \(tree.stacks.count) (expected 1)")
            for stack in tree.stacks {
                print("root \(stack.root.ref), \(stack.nodeCount) branches (expected 9)")
                let layout = StackLayout(root: stack.root)
                print("mainline: \(layout.mainline.map(\.ref).joined(separator: " → "))  (expected a → b → d → f)")
                for fork in layout.forks {
                    print("fork off \(fork.parentLeaf): \(fork.chain.map(\.ref).joined(separator: " → "))"
                          + (fork.deeper.isEmpty ? "" : "  drill-in: \(fork.deeper.map(\.ref).joined(separator: ","))"))
                }
                print("--- as rendered ---")
                printChain(stack.root, indent: 1)
            }
            return
        }
        // Debug/verification hook: render the stack list to a PNG and exit. The
        // dropdown itself can't be screenshotted without accessibility access,
        // so this is how the layout gets eyeballed.
        if let i = CommandLine.arguments.firstIndex(of: "--render"),
           i + 1 < CommandLine.arguments.count {
            await renderStackList(to: CommandLine.arguments[i + 1])
            return
        }
        // Debug/verification hook: open a cmux tab for a path and exit, no UI.
        if let i = CommandLine.arguments.firstIndex(of: "--open-cmux"),
           i + 1 < CommandLine.arguments.count {
            let outcome = await GitService.openInCmux(path: CommandLine.arguments[i + 1])
            print(outcome.ok ? "ok" : "error: \(outcome.message ?? "failed")")
            return
        }
        // Debug/verification hook: fire the conflict-resolution command in a cmux
        // tab for a path and exit, no UI.
        if let i = CommandLine.arguments.firstIndex(of: "--resolve-conflicts"),
           i + 1 < CommandLine.arguments.count {
            let outcome = await GitService.resolveConflicts(
                path: CommandLine.arguments[i + 1],
                command: CommandLine.arguments.count > i + 2
                    ? CommandLine.arguments[i + 2]
                    : Config.resolveConflictsCommand
            )
            print(outcome.ok ? "ok" : "error: \(outcome.message ?? "failed")")
            return
        }
        WorktreeManagerApp.main()
    }

    @MainActor
    private static func renderStackList(to path: String) async {
        // Both appearances have to be checked: the panel is mostly opacity-based
        // fills, which behave differently over a dark window background.
        let dark = CommandLine.arguments.contains("--dark")
        if dark {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        // --demo and --forks draw from SampleData, so the panel can be looked at
        // on a machine with no repo, no gh and no network. Nothing is fetched in
        // those modes, so the live repositories are never actually called.
        let store = Store()
        if CommandLine.arguments.contains("--forks") {
            store.injectForRender(worktrees: [], pullRequests: SampleData.forkedStackPullRequests)
        } else if CommandLine.arguments.contains("--demo") {
            store.injectForRender(worktrees: SampleData.demoWorktrees,
                                  pullRequests: SampleData.demoPullRequests)
        } else {
            await store.refresh()
            await store.refreshPullRequests()
        }

        // Avatars arrive asynchronously; the render is a single snapshot, so
        // wait for them rather than shooting a row of grey placeholders.
        let urls = Set(store.pullRequests.flatMap { $0.participants.map(\.avatarURL) })
        for url in urls { AvatarCache.shared.load(url) }
        for _ in 0..<60 where AvatarCache.shared.images.count < urls.count {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // The sections are composed directly rather than through StackListView,
        // whose ScrollView renders empty offscreen. Header and footer are the
        // real ones, so the whole panel can be eyeballed in one shot.
        let expanded = CommandLine.arguments.contains("--expand-first")
            ? store.stacks.first?.root.ref
            : nil
        let view = VStack(spacing: 0) {
            PanelHeader()
            Divider()
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                ForEach(store.stacks) { stack in
                    StackSection(
                        stack: stack,
                        collapsed: false,
                        onToggle: {},
                        expandedRef: .constant(expanded),
                        onBranchFrom: { _ in }, onDelete: { _ in },
                        onAddWorktree: { _ in }, onDrillIn: { _ in }
                    )
                }
                if !store.mergedWorktrees.isEmpty {
                    MergedSection(worktrees: store.mergedWorktrees)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 8)
            Divider()
            PanelFooter(onNew: {}, onAddExisting: {})
        }
        .environmentObject(store)
        .environment(\.colorScheme, dark ? .dark : .light)
        .frame(width: Metrics.panelWidth)
        .background(dark ? Color(red: 0.13, green: 0.13, blue: 0.14) : Color(nsColor: .windowBackgroundColor))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(Int(image.size.width))x\(Int(image.size.height)), \(store.stacks.count) stacks, \(AvatarCache.shared.images.count)/\(urls.count) avatars)")
    }

    // Mirrors StackLayout: the mainline prints flat, each fork prints under a
    // "branched off" label, so the text output shows what the menu will show.
    private static func printChain(_ root: StackNode, indent: Int) {
        let layout = StackLayout(root: root)
        let pad = String(repeating: "  ", count: indent)
        for node in layout.mainline {
            var bits: [String] = []
            if let pr = node.pr {
                bits.append("#\(pr.number)")
                bits.append("ci:\(pr.ci.rawValue)")
                if pr.mergeable == .conflicting { bits.append("CONFLICTS") }
                if pr.isDraft { bits.append("draft") }
                if pr.review == .approved { bits.append("approved") }
                if pr.review == .changesRequested { bits.append("changes-requested") }
                if pr.unresolvedThreads > 0 { bits.append("\(pr.unresolvedThreads) unresolved") }
                let who = pr.participants.prefix(3).map { $0.login + ($0.isBot ? "(bot)" : "") }
                if !who.isEmpty { bits.append("[" + who.joined(separator: ",") + "]") }
            } else {
                bits.append("no-PR")
            }
            if let wt = node.worktree {
                if wt.conflicts { bits.append("MERGE-CONFLICT") }
                if wt.dirty { bits.append("\(wt.dirtyCount) dirty") }
                if wt.unpushed > 0 { bits.append("↑\(wt.unpushed)") }
            } else {
                bits.append("ghost")
            }
            print("\(pad)● \(node.leaf)  \(bits.joined(separator: " · "))")
        }
        for fork in layout.forks {
            print("\(pad)  ↳ branched off \(fork.parentLeaf)")
            for node in fork.chain {
                print("\(pad)    ● \(node.leaf)\(node.pr.map { "  #\($0.number)" } ?? "  no-PR")")
            }
            if !fork.deeper.isEmpty {
                print("\(pad)    → \(fork.deeper.count) more branch(es) below (drill-in)")
            }
        }
    }
}

struct WorktreeManagerApp: App {
    @StateObject private var store = Store()

    init() {
        // Menu bar app: no Dock icon even when launched outside the bundle
        // (Info.plist's LSUIElement covers the bundled case).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Worktrees", systemImage: "tree") {
            MenuView()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
