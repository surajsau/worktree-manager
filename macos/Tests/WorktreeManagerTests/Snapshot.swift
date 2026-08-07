import AppKit
import SwiftUI
@testable import WorktreeManager

// Renders a view offscreen and lets a test ask questions about the pixels.
// Not golden-image comparison: reference PNGs go stale on every OS font change
// and tell you "something moved" rather than what. These ask the questions
// DESIGN.md actually cares about — how tall is a row, is there any alarm colour
// on a healthy panel, did the PR number keep its column.
@MainActor
enum Snapshot {

    struct Image {
        let rep: NSBitmapImageRep

        var width: Int { rep.pixelsWide }
        var height: Int { rep.pixelsHigh }

        func ink(at x: Int, _ y: Int) -> Ink {
            guard x >= 0, y >= 0, x < width, y < height,
                  let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return .none }
            return Ink(color)
        }

        // Pixel counts inside a rect, in points from the top-left.
        func count(_ rect: Rect, where predicate: (Ink) -> Bool) -> Int {
            var found = 0
            for y in rect.yRange(height: height) {
                for x in rect.xRange(width: width) where predicate(ink(at: x, y)) {
                    found += 1
                }
            }
            return found
        }

        func count(where predicate: (Ink) -> Bool) -> Int {
            count(.everything, where: predicate)
        }

        // Most of the panel is grey text on a soft fill, which carries no hue at
        // all — so "was anything drawn here" is a comparison against the
        // background, not a colour test. The background is measured inside the
        // rect (its most common colour), because the panel, the group fill and a
        // hovered row are three different backgrounds.
        func inkCount(in rect: Rect, threshold: CGFloat = 0.12) -> Int {
            var histogram: [Int: Int] = [:]
            var samples: [(x: Int, y: Int, color: NSColor)] = []
            for y in rect.yRange(height: height) {
                for x in rect.xRange(width: width) {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    samples.append((x, y, color))
                    histogram[Self.bucket(color), default: 0] += 1
                }
            }
            guard let background = histogram.max(by: { $0.value < $1.value })?.key else { return 0 }
            return samples.filter { Self.distance(Self.bucket($0.color), background) > threshold }.count
        }

        func hasInk(in rect: Rect) -> Bool {
            // A stray antialiased pixel or two on a boundary isn't content.
            inkCount(in: rect) > 8
        }

        private static func bucket(_ color: NSColor) -> Int {
            let r = Int(color.redComponent * 32)
            let g = Int(color.greenComponent * 32)
            let b = Int(color.blueComponent * 32)
            return (r << 10) | (g << 5) | b
        }

        private static func distance(_ a: Int, _ b: Int) -> CGFloat {
            let components: (Int) -> (CGFloat, CGFloat, CGFloat) = {
                (CGFloat(($0 >> 10) & 31) / 32, CGFloat(($0 >> 5) & 31) / 32, CGFloat($0 & 31) / 32)
            }
            let (r1, g1, b1) = components(a)
            let (r2, g2, b2) = components(b)
            return abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2)
        }
    }

    struct Rect {
        var x: Int = 0
        var y: Int = 0
        var width: Int?
        var height: Int?

        static let everything = Rect()

        func xRange(width bound: Int) -> Range<Int> {
            let end = min(bound, x + (width ?? bound))
            return min(x, end)..<end
        }

        func yRange(height bound: Int) -> Range<Int> {
            let end = min(bound, y + (height ?? bound))
            return min(y, end)..<end
        }
    }

    // Colour buckets by hue, so a test can say "no warm colour anywhere" without
    // hard-coding the exact greens and oranges the design uses.
    enum Ink: Equatable {
        case none      // background or unsaturated text
        case red
        case orange
        case yellow
        case green
        case blue
        case other

        init(_ color: NSColor) {
            let saturation = color.saturationComponent
            let brightness = color.brightnessComponent
            // Antialiasing haloes are washed out; only committed colour counts.
            guard saturation > 0.35, brightness > 0.35 else { self = .none; return }
            switch color.hueComponent {
            case ..<0.045, 0.95...: self = .red
            case ..<0.105: self = .orange
            case ..<0.19: self = .yellow
            case ..<0.45: self = .green
            case 0.5..<0.75: self = .blue
            default: self = .other
            }
        }

        // Everything the panel uses to say "this is not fine".
        var isAlarm: Bool { self == .red || self == .orange || self == .yellow }
    }

    static func render<V: View>(_ view: V, width: CGFloat = Metrics.panelWidth, dark: Bool = false) -> Image {
        let background = dark
            ? Color(red: 0.13, green: 0.13, blue: 0.14)
            : Color(red: 0.96, green: 0.96, blue: 0.96)
        let wrapped = view
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: width)
            .background(background)
        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return Image(rep: NSBitmapImageRep())
        }
        return Image(rep: rep)
    }

    // A store on fakes, holding the given data: no disk, no git, no network.
    static func store(worktrees: [Worktree], pullRequests: [PullRequest]) -> Store {
        let store = Store(git: FakeWorktreeRepository(worktrees),
                          github: FakePullRequestRepository(pullRequests),
                          cache: InMemoryPRSnapshotStore(),
                          avatars: RecordingAvatarLoader())
        store.injectForRender(worktrees: worktrees, pullRequests: pullRequests)
        return store
    }

    // A section wired up the way the list wires it: real store, no callbacks.
    static func section(
        worktrees: [Worktree],
        pullRequests: [PullRequest],
        collapsed: Bool = false,
        expandedRef: String? = nil,
        cmuxAvailable: Bool = true
    ) -> (view: AnyView, store: Store) {
        let store = store(worktrees: worktrees, pullRequests: pullRequests)
        let stack = store.stacks[0]
        let view = StackSection(
            stack: stack,
            collapsed: collapsed,
            onToggle: {},
            expandedRef: .constant(expandedRef),
            onBranchFrom: { _ in }, onDelete: { _ in },
            onAddWorktree: { _ in }, onDrillIn: { _ in }
        )
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 8)
        .environmentObject(store)
        .environment(\.cmuxAvailable, cmuxAvailable)
        return (AnyView(view), store)
    }
}

extension Snapshot.Rect {
    // Overlap of a column and a row band — "this cell of the row grid".
    func intersect(_ other: Snapshot.Rect) -> Snapshot.Rect {
        let x0 = max(x, other.x)
        let y0 = max(y, other.y)
        let x1 = min(x + (width ?? Int(Metrics.panelWidth)), other.x + (other.width ?? Int(Metrics.panelWidth)))
        let y1 = min(y + (height ?? 10_000), other.y + (other.height ?? 10_000))
        return Snapshot.Rect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
}
