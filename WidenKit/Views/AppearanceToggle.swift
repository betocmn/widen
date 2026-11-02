import SwiftUI

/// Three-segment Light / Dark / System switch in the sidebar footer.
struct AppearanceToggle: View {
    @AppStorage(AppearancePreference.storageKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

    var body: some View {
        HStack(spacing: 1) {
            segment(.light, icon: "sun.max", help: "Light mode")
            segment(.dark, icon: "moon", help: "Dark mode")
            segment(.system, icon: "display", help: "Follow the system appearance")
        }
        .padding(2)
        .background(Capsule().fill(.primary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Appearance")
    }

    private func segment(
        _ preference: AppearancePreference, icon: String, help: String
    ) -> some View {
        CapsuleSegmentButton(
            icon: icon,
            isSelected: appearanceRaw == preference.rawValue,
            help: help
        ) {
            appearanceRaw = preference.rawValue
        }
    }
}
