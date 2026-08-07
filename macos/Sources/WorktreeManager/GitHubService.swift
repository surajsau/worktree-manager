import AppKit
import Foundation

// PR data for the stack view, read through `gh` so it reuses the user's
// existing auth. One GraphQL query covers every open PR (~2.7s for 23 PRs);
// the REST equivalent via `gh pr list --json comments,statusCheckRollup` costs
// ~5s and 400KB because it returns every individual check run.
enum GitHubService {

    private static let query = """
    query($q: String!) {
      search(query: $q, type: ISSUE, first: 100) {
        nodes {
          ... on PullRequest {
            number title url isDraft mergeable reviewDecision
            headRefName baseRefName updatedAt additions deletions
            comments(last: 20) { nodes { author { __typename login avatarUrl(size: 48) } } }
            reviewThreads(first: 40) {
              nodes {
                isResolved
                comments(first: 1) { nodes { author { __typename login avatarUrl(size: 48) } } }
              }
            }
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          }
        }
      }
    }
    """

    struct Failure: Error {
        let message: String
    }

    static func fetchPullRequests() async -> Result<[PullRequest], Failure> {
        guard Config.isConfigured else {
            return .failure(Failure(message: "no repository set — choose one in Settings"))
        }
        guard let gh = Config.ghPath else {
            return .failure(Failure(message: "gh CLI not found — install it with `brew install gh`"))
        }
        guard let slug = await repoSlug() else {
            return .failure(Failure(message: "could not read the GitHub repo from origin's remote URL"))
        }
        guard let login = await viewerLogin(gh: gh) else {
            return .failure(Failure(message: "gh is not logged in — run `gh auth login`"))
        }

        let res = await GitService.run(gh, [
            "api", "graphql",
            "-f", "query=\(query)",
            "-f", "q=repo:\(slug) is:pr is:open author:\(login)",
        ], cwd: Config.mainRepo)

        if res.code != 0 {
            let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(Failure(message: err.isEmpty ? "gh api graphql failed" : err))
        }
        guard let data = res.stdout.data(using: .utf8) else {
            return .failure(Failure(message: "gh returned no output"))
        }
        do {
            return .success(try parse(data, viewer: login))
        } catch {
            return .failure(Failure(message: "could not read gh's response: \(error.localizedDescription)"))
        }
    }

    // MARK: - Parsing

    // Hand-rolled rather than Codable: the payload is deeply nested with
    // several `... on PullRequest` holes, and the shape we want out is flat.
    private static func parse(_ data: Data, viewer: String) throws -> [PullRequest] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "unexpected JSON")
        }
        if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
            let messages = errors.compactMap { $0["message"] as? String }
            throw Failure(message: messages.joined(separator: "; "))
        }
        let nodes = ((root["data"] as? [String: Any])?["search"] as? [String: Any])?["nodes"] as? [[String: Any]]
        let formatter = ISO8601DateFormatter()

        return (nodes ?? []).compactMap { node in
            guard let number = node["number"] as? Int,
                  let head = node["headRefName"] as? String,
                  let base = node["baseRefName"] as? String else { return nil }

            var byLogin: [String: Commenter] = [:]
            func record(_ author: [String: Any]?, unresolved: Bool, comment: Bool) {
                guard let author,
                      let login = author["login"] as? String,
                      let avatar = author["avatarUrl"] as? String else { return }
                var entry = byLogin[login]
                    ?? Commenter(login: login, avatarURL: avatar,
                                 isBot: (author["__typename"] as? String) == "Bot",
                                 isViewer: login == viewer,
                                 unresolved: 0, comments: 0)
                if unresolved { entry.unresolved += 1 }
                if comment { entry.comments += 1 }
                byLogin[login] = entry
            }

            let comments = (node["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            for comment in comments {
                record(comment["author"] as? [String: Any], unresolved: false, comment: true)
            }

            let threads = (node["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            var unresolvedCount = 0
            for thread in threads where !((thread["isResolved"] as? Bool) ?? false) {
                unresolvedCount += 1
                let first = ((thread["comments"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first
                record(first?["author"] as? [String: Any], unresolved: true, comment: false)
            }

            let rollup = ((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?
                .first
                .flatMap { ($0["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any] }
            let updated = (node["updatedAt"] as? String).flatMap { formatter.date(from: $0) }

            // People before bots, and whoever left an unresolved thread first:
            // the avatar row is cut off at three, so ordering decides who shows.
            let participants = byLogin.values.sorted { lhs, rhs in
                if lhs.unresolved != rhs.unresolved { return lhs.unresolved > rhs.unresolved }
                if lhs.isBot != rhs.isBot { return !lhs.isBot }
                return lhs.login < rhs.login
            }

            return PullRequest(
                number: number,
                title: (node["title"] as? String) ?? "",
                url: (node["url"] as? String) ?? "",
                headRef: head,
                baseRef: base,
                isDraft: (node["isDraft"] as? Bool) ?? false,
                mergeable: Mergeability(raw: node["mergeable"] as? String),
                review: ReviewState(raw: node["reviewDecision"] as? String),
                ci: CIState(rollup: rollup?["state"] as? String),
                unresolvedThreads: unresolvedCount,
                additions: (node["additions"] as? Int) ?? 0,
                deletions: (node["deletions"] as? Int) ?? 0,
                updatedAt: updated ?? Date(timeIntervalSince1970: 0),
                participants: participants
            )
        }
    }

    // MARK: - Repo / viewer

    private static func viewerLogin(gh: String) async -> String? {
        let res = await GitService.run(gh, ["api", "user", "-q", ".login"], cwd: Config.mainRepo)
        let login = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return res.code == 0 && !login.isEmpty ? login : nil
    }

    // Parsed from the remote URL rather than `gh repo view` so it costs no
    // network round trip. Handles both SSH and HTTPS remotes.
    private static func repoSlug() async -> String? {
        let res = await GitService.git(["config", "--get", "remote.origin.url"])
        var url = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        if url.hasSuffix(".git") { url = String(url.dropLast(4)) }
        if let range = url.range(of: "github.com") {
            // Drops the ":" of git@github.com: and the "/" of https://github.com/.
            let tail = url[range.upperBound...].drop { $0 == ":" || $0 == "/" }
            return tail.split(separator: "/").count == 2 ? String(tail) : nil
        }
        return nil
    }

    // MARK: - Open in browser

    static func openPR(_ pr: PullRequest) {
        guard let url = URL(string: pr.url) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Snapshot cache

// PR state is cached on disk so the stack view has numbers on it the instant
// the menu opens after a relaunch, rather than 3 seconds later.
enum PRCache {
    private static var fileURL: URL {
        URL(fileURLWithPath: Config.cacheDir).appendingPathComponent("pull-requests.json")
    }

    static func load() -> PRSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PRSnapshot.self, from: data)
    }

    static func save(_ snapshot: PRSnapshot) {
        try? FileManager.default.createDirectory(
            atPath: Config.cacheDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Avatars

// Comment authors are shown as avatars, so the icons have to be fetched and
// then survive a relaunch (they never change, so the disk copy has no TTL).
@MainActor
final class AvatarCache: ObservableObject {
    static let shared = AvatarCache()

    @Published private(set) var images: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    private var dir: URL {
        URL(fileURLWithPath: Config.cacheDir).appendingPathComponent("avatars")
    }

    // Pure lookup. Loading is never kicked off from here: `images` is
    // @Published, and touching it while SwiftUI is evaluating a body is the
    // "Publishing changes from within view updates" trap. Views call load()
    // from .task instead.
    func image(for url: String) -> NSImage? {
        images[url]
    }

    func load(_ url: String) {
        guard images[url] == nil, !inFlight.contains(url), let remote = URL(string: url) else { return }
        inFlight.insert(url)
        let file = dir.appendingPathComponent(Self.key(for: url))

        Task { [dir] in
            defer { inFlight.remove(url) }
            // Disk first — avatars never change, so the cached copy has no TTL.
            if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
                images[url] = image
                return
            }
            guard let (data, _) = try? await URLSession.shared.data(from: remote),
                  let image = NSImage(data: data) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            images[url] = image
        }
    }

    // Avatar URLs carry query strings, so they can't be filenames as-is.
    private static func key(for url: String) -> String {
        String(url.unicodeScalars.map { $0.properties.isAlphabetic || $0.properties.numericType != nil ? Character($0) : "-" })
            .suffix(80)
            .description
    }
}
