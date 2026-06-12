import SwiftUI

/// One segment of a capsule toggle (Local/Cloud, appearance): icon plus
/// optional label, a filled capsule when selected, and a lighter capsule
/// while hovered — custom controls don't get the system hover treatment.
struct CapsuleSegmentButton: View {
    let icon: String
    var title: String?
    var iconSize: CGFloat = 12
    let isSelected: Bool
    var isWarning = false
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .medium))
                if let title {
                    Text(title)
                        .font(.callout)
                }
            }
            .foregroundStyle(
                isWarning
                    ? AnyShapeStyle(.orange)
                    : (isSelected || isHovering
                        ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            )
            .padding(.horizontal, title == nil ? 8 : 10)
            .padding(.vertical, 4.5)
            .background {
                if isSelected {
                    Capsule().fill(.primary.opacity(0.12))
                } else if isHovering {
                    Capsule().fill(.primary.opacity(0.07))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Capsule hover tint for borderless buttons (footer, inline headers),
/// which macOS leaves without any hover feedback.
struct HoverHighlight: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                if isHovering {
                    Capsule().fill(.primary.opacity(0.07))
                }
            }
            .onHover { isHovering = $0 }
    }
}

extension View {
    func hoverHighlight() -> some View {
        modifier(HoverHighlight())
    }
}
