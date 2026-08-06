import AppKit
import Foundation

// Port of the git operations from server.js. Commands run without a shell
// (arg arrays => no injection), and never throw — errors come back in the
// result so callers can surface git's own messages.
enum GitService {

    static func run(_ executable: String, _ args: [String], cwd: String? = nil) async -> CommandResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    cont.resume(returning: CommandResult(code: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                // Drain pipes before waiting, or a chatty child can deadlock.
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: CommandResult(
                    code: process.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }
        }
    }

    static func git(_ args: [String], cwd: String = Config.mainRepo) async -> CommandResult {
        await run("/usr/bin/git", args, cwd: cwd)
    }

    // MARK: - List

    static func listWorktrees() async -> [Worktree] {
        let res = await git(["worktree", "list", "--porcelain"])
        var entries: [(path: String, branch: String?)] = []
        var curPath: String?
        var curBranch: String?
        for line in res.stdout.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                if let p = curPath { entries.append((p, curBranch)) }
                curPath = String(line.dropFirst("worktree ".count))
                curBranch = nil
            } else if line.hasPrefix("branch "), curPath != nil {
                curBranch = String(line.dropFirst("branch ".count))
                    .replacingOccurrences(of: "refs/heads/", with: "")
            }
        }
        if let p = curPath { entries.append((p, curBranch)) }

        let prefix = Config.worktreeDir + "/"
        let managed = entries.filter { $0.path.hasPrefix(prefix) }

        return await withTaskGroup(of: Worktree.self) { group in
            for entry in managed {
                group.addTask { await status(path: entry.path, branch: entry.branch) }
            }
            var result: [Worktree] = []
            for await wt in group { result.append(wt) }
            return result.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    private static func status(path: String, branch: String?) async -> Worktree {
        async let dirtyRes = git(["status", "--porcelain"], cwd: path)
        async let baseRefRes = determinBaseRef(branch: branch, cwd: path)
        async let unpushedRes = git(["rev-list", "--count", "HEAD", "--not", "--remotes"], cwd: path)
        // The commits this branch adds on top of the trunk: an empty list means
        // it is fully merged, and the SHAs let StackBuilder find the branch's
        // parent when there is no PR to name a base.
        async let aboveTrunkRes = git(["rev-list", "HEAD", "--not", Config.trunkRef], cwd: path)
        async let tipRes = git(["rev-parse", "HEAD"], cwd: path)
        async let behindTrunkRes = git(["rev-list", "--count", "HEAD..\(Config.trunkRef)"], cwd: path)
        async let ownCommitsRes = hasOwnCommits(branch: branch, cwd: path)
        let (dirty, baseRef, unpushedR) = await (dirtyRes, baseRefRes, unpushedRes)
        let (aboveTrunk, tipR, behindTrunkR) = await (aboveTrunkRes, tipRes, behindTrunkRes)
        let ownCommits = await ownCommitsRes

        async let aheadBehindRes = git(["rev-list", "--left-right", "--count", "\(baseRef)...HEAD"], cwd: path)
        let aheadBehind = await aheadBehindRes

        let statusLines = dirty.stdout.split(separator: "\n").map(String.init)
        // Unmerged status codes (both-modified etc.) mean a merge conflict is unresolved.
        let conflictCodes: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]
        let conflicts = statusLines.contains { line in
            line.count >= 3 && conflictCodes.contains(String(line.prefix(2)))
                && line[line.index(line.startIndex, offsetBy: 2)] == " "
        }

        var ahead = 0
        var behind = 0
        if aheadBehind.code == 0 {
            let parts = aheadBehind.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
            if parts.count == 2 {
                behind = Int(parts[0]) ?? 0
                ahead = Int(parts[1]) ?? 0
            }
        }
        let unpushed = unpushedR.code == 0
            ? Int(unpushedR.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            : 0

        let branchName = branch ?? "(detached)"
        let artifacts = agentArtifacts(branch: branch)
        let contained = Set(aboveTrunk.stdout.split(whereSeparator: \.isNewline).map(String.init))
        return Worktree(
            branch: branchName,
            name: branch.map { $0.hasPrefix(Config.branchPrefix) ? String($0.dropFirst(Config.branchPrefix.count)) : $0 } ?? branchName,
            path: path,
            folder: (path as NSString).lastPathComponent,
            dirty: !statusLines.isEmpty,
            dirtyCount: statusLines.count,
            conflicts: conflicts,
            ahead: ahead,
            behind: behind,
            unpushed: unpushed,
            ticketPath: artifacts.ticket,
            shipRunPath: artifacts.shipRun,
            commitsAboveTrunk: contained.count,
            hasOwnCommits: ownCommits,
            behindTrunk: Int(behindTrunkR.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
            tip: tipR.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            containedTips: contained
        )
    }

    // Did a commit ever land on this branch? The branch reflog keeps every
    // entry that moved the ref, and commit entries are never rewritten away —
    // a rebased branch still shows the original `commit:` lines. A branch that
    // has only its `branch: Created from …` entry has never been worked on.
    //
    // Reflog subjects that mean own work: `commit:`, `commit (amend):`,
    // `rebase (pick):`, `cherry-pick:`, `am:`, `revert:`. A `merge …:
    // Fast-forward` is explicitly not own work — that is the trunk catching a
    // branch up, which leaves it just as empty as it was.
    private static func hasOwnCommits(branch: String?, cwd: String) async -> Bool {
        // Detached HEAD has no branch reflog to read; assume real history
        // rather than calling it a fresh branch.
        guard let branch else { return true }
        let res = await git(["reflog", "show", "--format=%gs", branch], cwd: cwd)
        guard res.code == 0 else { return true }
        let ownWork = ["commit", "rebase", "cherry-pick", "am", "revert"]
        return res.stdout.split(separator: "\n").contains { line in
            let subject = line.trimmingCharacters(in: .whitespaces)
            guard let verb = subject.split(whereSeparator: { $0 == " " || $0 == ":" }).first else { return false }
            if verb == "merge" { return !subject.hasSuffix("Fast-forward") }
            return ownWork.contains(String(verb))
        }
    }

    // MARK: - Trunk freshness

    // Merged-branch detection and stack roots are measured against the local
    // origin/main ref, which is only as fresh as the last fetch — a stale one
    // under-reports merges. Run before a full refresh, not on every menu open.
    static func fetchTrunk() async {
        _ = await git(["fetch", "origin", Config.trunkRef.shortRef, "--quiet"])
    }

    // A branch's agent artifacts: the tracker feature dir and the ship run dir,
    // matched against the branch's path segments, last first (mirrors
    // agent-artifacts.sh, which serves the shell scripts).
    private static func agentArtifacts(branch: String?) -> (ticket: String?, shipRun: String?) {
        guard let branch else { return (nil, nil) }
        let fm = FileManager.default
        var ticket: String?
        var shipRun: String?
        for seg in branch.split(separator: "/").map(String.init).reversed() {
            var isDir: ObjCBool = false
            if ticket == nil {
                let p = Config.trackerScratchDir + "/" + seg
                if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { ticket = p }
            }
            if shipRun == nil {
                let p = Config.shipRunsDir + "/" + seg
                if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { shipRun = p }
            }
        }
        return (ticket, shipRun)
    }

    private static func determinBaseRef(branch: String?, cwd: String) async -> String {
        guard let branch = branch else { return "origin/main" }
        let checkRef = await git(["rev-parse", "-q", "--verify", "origin/\(branch)@{upstream}"], cwd: cwd)
        if checkRef.code == 0 {
            return "origin/\(branch)"
        }
        let checkRemote = await git(["rev-parse", "-q", "--verify", "origin/\(branch)"], cwd: cwd)
        if checkRemote.code == 0 {
            return "origin/\(branch)"
        }
        return "origin/main"
    }

    // MARK: - Base branches

    // Start-point candidates for a new worktree: origin's remote-tracking
    // branches (as of the last fetch) plus every local branch, with
    // origin/main pinned first. Remote refs come before locals because that's
    // what a new worktree usually branches off.
    static func listBaseBranches() async -> [String] {
        async let remotesRes = git(["for-each-ref", "--format=%(refname)", "refs/remotes/origin"])
        async let localsRes = git(["for-each-ref", "--format=%(refname)", "refs/heads"])
        let (remotes, locals) = await (remotesRes, localsRes)

        let remoteNames = refNames(remotes, stripping: "refs/remotes/")
        let ordered = (remoteNames.contains(Config.defaultBase) ? [Config.defaultBase] : [])
            + remoteNames
            + refNames(locals, stripping: "refs/heads/")
        var seen = Set<String>()
        return ordered.filter { seen.insert($0).inserted }
    }

    private static func refNames(_ res: CommandResult, stripping prefix: String) -> [String] {
        res.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            // origin/HEAD is a symref alias for the default branch, not a branch
            // (and %(refname:short) would render it as a bare "origin").
            .filter { !$0.isEmpty && $0 != "refs/remotes/origin/HEAD" }
            .map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Create / add existing (delegates to the shell scripts)

    static func createWorktree(name: String, base: String?) async -> OpOutcome {
        var args = [Config.createScript, name]
        if let base, !base.isEmpty { args.append(base) }
        let res = await run("/bin/bash", args)
        return scriptOutcome(res, fallbackError: "create failed")
    }

    static func addExistingWorktree(branch: String) async -> OpOutcome {
        let res = await run("/bin/bash", [Config.addExistingScript, branch])
        return scriptOutcome(res, fallbackError: "add failed")
    }

    private static func scriptOutcome(_ res: CommandResult, fallbackError: String) -> OpOutcome {
        let output = [res.stdout, res.stderr]
            .filter { !$0.isEmpty }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if res.code != 0 {
            var msg = output
            if msg.hasPrefix("error: ") { msg = String(msg.dropFirst("error: ".count)) }
            return OpOutcome(ok: false, message: msg.isEmpty ? fallbackError : msg)
        }
        return OpOutcome(ok: true, message: output.isEmpty ? nil : output)
    }

    // MARK: - Delete

    static func deleteWorktree(path: String, branch: String) async -> OpOutcome {
        guard path.hasPrefix(Config.worktreeDir + "/") else {
            return OpOutcome(ok: false, message: "refusing to delete: path is not a managed worktree")
        }
        let rm = await git(["worktree", "remove", "--force", path])
        if rm.code != 0 {
            let msg = firstNonEmpty(rm.stderr, rm.stdout) ?? "git worktree remove failed"
            return OpOutcome(ok: false, message: msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !branch.isEmpty && branch != "(detached)" {
            let del = await git(["branch", "-D", branch])
            if del.code != 0 {
                let msg = firstNonEmpty(del.stderr, del.stdout) ?? ""
                return OpOutcome(
                    ok: true,
                    message: "worktree removed, but deleting branch failed:\n\(msg.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
            }
        }
        return OpOutcome(ok: true, message: "Deleted \(branch).")
    }

    // MARK: - Pull latest

    // Fetch the latest origin/main and merge it into the worktree's branch.
    // On conflict the merge is left in progress (resolve in Android Studio /
    // abort with `git merge --abort`) and we report it so the UI can warn.
    static func pullLatest(path: String) async -> OpOutcome {
        guard path.hasPrefix(Config.worktreeDir + "/") else {
            return OpOutcome(ok: false, message: "refusing to pull: path is not a managed worktree")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return OpOutcome(ok: false, message: "worktree folder no longer exists")
        }

        let merging = await git(["rev-parse", "-q", "--verify", "MERGE_HEAD"], cwd: path)
        if merging.code == 0 {
            return OpOutcome(ok: false, message: "a merge is already in progress — resolve or abort it first")
        }

        let fetch = await git(["fetch", "origin", "main"], cwd: path)
        if fetch.code != 0 {
            let msg = fetch.stderr.isEmpty ? "git fetch failed" : fetch.stderr
            return OpOutcome(ok: false, message: msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let merge = await git(["merge", "--no-edit", "origin/main"], cwd: path)
        if merge.code == 0 {
            let upToDate = merge.stdout.range(of: "Already up to date", options: .caseInsensitive) != nil
            return OpOutcome(ok: true, message: upToDate ? "Already up to date." : "Merged latest origin/main.")
        }

        let unmerged = await git(["diff", "--name-only", "--diff-filter=U"], cwd: path)
        let unmergedFiles = unmerged.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if unmerged.code == 0 && !unmergedFiles.isEmpty {
            let files = unmergedFiles.split(separator: "\n")
            return OpOutcome(
                ok: false,
                message: "Merge conflict in \(files.count) file\(files.count == 1 ? "" : "s")"
                    + " — resolve in Android Studio (or run `git merge --abort`):\n"
                    + files.joined(separator: "\n"),
                conflict: true
            )
        }
        let msg = firstNonEmpty(merge.stderr, merge.stdout) ?? "git merge failed"
        return OpOutcome(ok: false, message: msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Open

    static func open(path: String, app: String) async -> OpOutcome {
        guard path.hasPrefix(Config.worktreeDir + "/") else {
            return OpOutcome(ok: false, message: "refusing to open: path is not a managed worktree")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return OpOutcome(ok: false, message: "worktree folder no longer exists")
        }
        let res = await run("/usr/bin/open", ["-a", app, path])
        if res.code != 0 {
            let msg = res.stderr.isEmpty ? "failed to open \(app)" : res.stderr
            return OpOutcome(ok: false, message: msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return OpOutcome(ok: true)
    }

    // MARK: - Open in cmux

    // Focus the cmux tab whose terminal is at this worktree's directory, or
    // open a new one there. Drives the CLI bundled inside cmux.app (talks to
    // the app over its unix socket); `cmux <path>` also launches the app.
    static func openInCmux(path: String) async -> OpOutcome {
        guard path.hasPrefix(Config.worktreeDir + "/") else {
            return OpOutcome(ok: false, message: "refusing to open: path is not a managed worktree")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return OpOutcome(ok: false, message: "worktree folder no longer exists")
        }
        guard let cli = cmuxCLI else {
            return OpOutcome(ok: false, message: "cmux.app not found")
        }

        let list = await run(cli, ["workspace", "list", "--json"])
        if list.code == 0 {
            if let ref = cmuxWorkspaceRef(listJSON: list.stdout, at: path) {
                let sel = await run(cli, ["workspace", "select", ref])
                if sel.code == 0 {
                    _ = await run("/usr/bin/open", ["-b", Config.cmuxBundleID])
                    return OpOutcome(ok: true)
                }
            }
            let res = await run(cli, ["workspace", "create", "--cwd", path, "--focus", "true"])
            if res.code != 0 {
                let msg = firstNonEmpty(res.stderr, res.stdout) ?? "failed to open cmux tab"
                return OpOutcome(ok: false, message: msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            _ = await run("/usr/bin/open", ["-b", Config.cmuxBundleID])
            return OpOutcome(ok: true)
        }

        // Listing failed — cmux isn't running. `cmux <path>` launches it with
        // a workspace at that directory.
        let res = await run(cli, [path])
        if res.code != 0 {
            let msg = firstNonEmpty(res.stderr, res.stdout) ?? "failed to launch cmux"
            return OpOutcome(ok: false, message: msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return OpOutcome(ok: true)
    }

    private static let cmuxCLI: String? = {
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Config.cmuxBundleID)
            ?? URL(fileURLWithPath: "/Applications/cmux.app")
        let cli = app.appendingPathComponent("Contents/Resources/bin/cmux").path
        return FileManager.default.fileExists(atPath: cli) ? cli : nil
    }()

    // `cmux workspace list --json` => { "workspaces": [ { "ref", "current_directory", … } ] }
    private static func cmuxWorkspaceRef(listJSON: String, at path: String) -> String? {
        guard let data = listJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        // Tolerate one window (object) or several (array of objects).
        let windows: [[String: Any]]
        if let dict = obj as? [String: Any] {
            windows = [dict]
        } else if let arr = obj as? [[String: Any]] {
            windows = arr
        } else {
            return nil
        }
        let target = normalized(path)
        for window in windows {
            for ws in window["workspaces"] as? [[String: Any]] ?? [] {
                if let dir = ws["current_directory"] as? String, normalized(dir) == target {
                    return ws["ref"] as? String
                }
            }
        }
        return nil
    }

    private static func normalized(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func firstNonEmpty(_ candidates: String...) -> String? {
        candidates.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
