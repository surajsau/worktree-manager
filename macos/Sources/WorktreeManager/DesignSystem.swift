import AppKit
import SwiftUI

// Design tokens for the whole panel. Every size, inset and colour the views use
// comes from here, so the legend in Settings and the rows it describes can't
// drift apart — and so "one more 9pt font" can't quietly happen. The rules
// these encode are written down in DESIGN.md.

enum Metrics {
    static let panelWidth: CGFloat = 420
    // Left edge everything lines up on: panel title, section titles, groups.
    static let gutter: CGFloat = 12
    static let rowHeight: CGFloat = 24
    // Gutter for the stack graph: rail line and CI dot live here.
    static let rail: CGFloat = 16
    static let dot: CGFloat = 7
    static let groupRadius: CGFloat = 8
    static let rowRadius: CGFloat = 6
    static let sectionGap: CGFloat = 10
    // PR numbers are right-aligned into a fixed column so they read as a column
    // and don't shift when hover actions appear beside them.
    static let prColumn: CGFloat = 50
    // Roughly two thirds of a 13" screen; past this the list scrolls.
    static let maxListHeight: CGFloat = 520
}

// Three sizes and one weight change. Anything that wants a fourth size is
// asking for a hierarchy this panel doesn't have.
enum Typo {
    static let sectionTitle = Font.system(size: 12, weight: .semibold)
    static let row = Font.system(size: 12)
    static let meta = Font.system(size: 11)
    static let metaEmphasis = Font.system(size: 11, weight: .medium)
}

// Colour is reserved for states that are not fine. Everything routine is
// primary or secondary text on a neutral fill.
enum StackStyle {
    static let rail = Color.primary.opacity(0.15)
    static let groupFill = Color.primary.opacity(0.04)
    static let rowHover = Color.primary.opacity(0.07)
    static let dirty = Color(red: 0.85, green: 0.62, blue: 0.10)
    static let ciPending = Color(red: 0.90, green: 0.75, blue: 0.20)
    static let attention = Color(red: 0.95, green: 0.55, blue: 0.10)

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
    static func nameColor(_ state: RowStatus.NameState) -> Color {
        switch state {
        case .ghost: return .secondary
        case .conflicted: return .red
        case .dirty: return dirty
        case .clean: return .primary
        }
    }
}

// MARK: - Shared bits

// A count that means "these need you". Soft-filled rather than a solid badge:
// at this size a filled orange capsule with white text shouts louder than
// anything it is pointing at.
struct AttentionPill: View {
    let count: Int
    var help: String = ""

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(StackStyle.attention)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(StackStyle.attention.opacity(0.15)))
            .help(help)
    }
}

// A disclosure header that owns a group below it — the macOS Settings pattern,
// where the title sits outside the container instead of adding another box.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    let expanded: Bool
    let onToggle: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 9)
                Text(title)
                    .font(Typo.sectionTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(Typo.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                trailing()
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// The one container in the list: a soft fill, no border. Borders on top of a
// panel that is already a floating surface read as boxes inside boxes.
struct GroupBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous)
                    .fill(StackStyle.groupFill)
            )
    }
}

extension View {
    func stackGroup() -> some View { modifier(GroupBox()) }
}

// MARK: - Buttons

struct MiniButton: View {
    let icon: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 20, height: 18)
        }
        .buttonStyle(HoverBackgroundButtonStyle(padding: 0))
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
                    Image(systemName: fallbackIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 18)
        }
        .buttonStyle(HoverBackgroundButtonStyle(padding: 0))
        .help(help)
    }
}

// Labelled rather than icon-only: it only appears on a conflicted row, where
// the extra width is free and "what does this red glyph do" is not a question
// worth making anyone ask.
struct ResolveConflictButton: View {
    var blockedByDirtyTree = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.merge")
                Text("Resolve")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.red)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.red.opacity(hovering ? 0.24 : 0.13)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var help: String {
        var text = "Resolve conflicts — opens a cmux tab here running `\(Config.resolveConflictsCommand)`,"
            + " which detects the base branch, merges it, and works through the conflicts."
        if blockedByDirtyTree {
            text += "\n\nUncommitted changes here will stop it: the merge refuses to start on a dirty tree."
        }
        return text
    }
}

struct HoverBackgroundButtonStyle: ButtonStyle {
    var padding: CGFloat = 6
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, padding)
            .padding(.vertical, padding > 0 ? 4 : 0)
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.15 : 0.08))
                    .opacity(hovering ? 1 : 0)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
