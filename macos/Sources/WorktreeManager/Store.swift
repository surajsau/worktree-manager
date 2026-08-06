import Foundation
import SwiftUI

@MainActor
final class Store: ObservableObject {
    struct Banner: Equatable {
        let text: String
        let isError: Bool
    }

    @Published var worktrees: [Worktree] = []
    @Published var isLoading = false
    @Published var hasLoadedOnce = false
    @Published var banner: Banner?
    @Published var busyPaths: Set<String> = []
    @Published var baseBranches: [String] = []
    @Published var isLoadingBranches = false

    // No auto-polling — git state is computed on demand only (dropdown open,
    // Refresh button, or after an action), to keep the always-on app idle.
    func refresh() async {
        if isLoading { return }
        isLoading = true
        worktrees = await GitService.listWorktrees()
        isLoading = false
        hasLoadedOnce = true
    }

    // Reads local refs only (no fetch), so it is cheap enough to redo whenever
    // the create form opens. Previous values stay on screen while it reloads.
    func loadBaseBranches() async {
        if isLoadingBranches { return }
        isLoadingBranches = true
        baseBranches = await GitService.listBaseBranches()
        isLoadingBranches = false
    }

    func create(name: String, base: String?) async -> OpOutcome {
        let outcome = await GitService.createWorktree(name: name, base: base)
        if outcome.ok {
            banner = Banner(text: "Created \(Config.branchPrefix)\(name).", isError: false)
            await refresh()
        }
        return outcome
    }

    func addExisting(branch: String) async -> OpOutcome {
        let outcome = await GitService.addExistingWorktree(branch: branch)
        if outcome.ok {
            banner = Banner(text: "Added worktree for \(branch).", isError: false)
            await refresh()
        }
        return outcome
    }

    func delete(_ wt: Worktree) async {
        busyPaths.insert(wt.path)
        let outcome = await GitService.deleteWorktree(path: wt.path, branch: wt.branch)
        busyPaths.remove(wt.path)
        banner = Banner(text: outcome.message ?? (outcome.ok ? "Deleted." : "delete failed"), isError: !outcome.ok)
        await refresh()
    }

    func pull(_ wt: Worktree) async {
        busyPaths.insert(wt.path)
        let outcome = await GitService.pullLatest(path: wt.path)
        busyPaths.remove(wt.path)
        banner = Banner(text: outcome.message ?? (outcome.ok ? "Done." : "pull failed"), isError: !outcome.ok)
        await refresh()
    }

    func open(_ wt: Worktree) async {
        await openInStudio(path: wt.path)
    }

    func openMainRepo() async {
        await openInStudio(path: Config.mainRepo)
    }

    private func openInStudio(path: String) async {
        let outcome = await GitService.open(path: path, app: Config.studioApp)
        if !outcome.ok {
            banner = Banner(text: outcome.message ?? "failed to open", isError: true)
        }
    }

    // Opens the settings-selected terminal; cmux gets its smarter
    // focus-or-create-tab flow, everything else a plain `open -a`.
    func openInTerminal(_ wt: Worktree) async {
        let terminal = TerminalApps.selected
        let outcome = terminal == TerminalApps.cmuxName
            ? await GitService.openInCmux(path: wt.path)
            : await GitService.open(path: wt.path, app: terminal)
        if !outcome.ok {
            banner = Banner(text: outcome.message ?? "failed to open \(terminal)", isError: true)
        }
    }

}
