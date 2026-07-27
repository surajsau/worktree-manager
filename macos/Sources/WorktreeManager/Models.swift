import Foundation

enum Config {
    static let mainRepo = "/Users/s24270/Documents/Github/abema-androidtv"
    static let worktreeDir = "/Users/s24270/Documents/Github/worktrees"
    static let branchPrefix = "suraj/"
    // The create/add logic lives in standalone shell scripts (shared with the
    // web server and Claude skills) — the app shells out to them.
    static let scriptsDir = "/Users/s24270/Documents/Github/worktree-manager"
    static var createScript: String { scriptsDir + "/create-worktree.sh" }
    static var addExistingScript: String { scriptsDir + "/add-existing-worktree.sh" }
    static let studioApp = "Android Studio"
    static let cmuxBundleID = "com.cmuxterm.app"
}

struct Worktree: Identifiable, Equatable, Sendable {
    let branch: String
    let name: String
    let path: String
    let folder: String
    let dirty: Bool
    let conflicts: Bool
    let ahead: Int
    let behind: Int
    let unpushed: Int

    var id: String { path }
}

struct OpOutcome: Sendable {
    var ok: Bool
    var message: String? = nil
    var conflict: Bool = false
}

struct CommandResult: Sendable {
    let code: Int32
    let stdout: String
    let stderr: String
}
