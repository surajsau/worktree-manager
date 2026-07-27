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
        let (dirty, baseRef, unpushedR) = await (dirtyRes, baseRefRes, unpushedRes)

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
        return Worktree(
            branch: branchName,
            name: branch.map { $0.hasPrefix(Config.branchPrefix) ? String($0.dropFirst(Config.branchPrefix.count)) : $0 } ?? branchName,
            path: path,
            folder: (path as NSString).lastPathComponent,
            dirty: !statusLines.isEmpty,
            conflicts: conflicts,
            ahead: ahead,
            behind: behind,
            unpushed: unpushed
        )
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
