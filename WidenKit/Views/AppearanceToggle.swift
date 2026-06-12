import SwiftUI

/// Three-segment System / Light / Dark switch in the sidebar footer, drawn
/// in the same capsule style as the toolbar's Local/Cloud toggle. Unlike the
/// toolbar control it sits outside the system glass, so it carries its own
/// subtle track.
struct AppearanceToggle: View {
    @AppStorage(AppearancePreference.storageKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

    var body: some View {
        HStack(spacing: 1) {
            segment(.system, icon: "circle.lefthalf.filled", help: "Follow the system appearance")
            segment(.light, icon: "sun.max", help: "Light mode")
            segment(.dark, icon: "moon", help: "Dark mode")
        }
        .padding(2)
        .background(Capsule().fill(.primary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Appearance")
    }

    private func segment(
        _ preference: AppearancePreference, icon: String, help: String
    ) -> some View {
        let isSelected = appearanceRaw == preference.rawValue
        return Button {
            appearanceRaw = preference.rawValue
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background {
                    if isSelected {
                        Capsule().fill(.primary.opacity(0.12))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
