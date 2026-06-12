import SwiftUI

/// Flips light/dark mode (sun/moon icon). Lives in the sidebar footer; the
/// "follow System" reset stays in Settings › General.
struct AppearanceToggle: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppearancePreference.storageKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

    var body: some View {
        Button {
            let next: AppearancePreference = colorScheme == .dark ? .light : .dark
            appearanceRaw = next.rawValue
        } label: {
            Label(
                colorScheme == .dark ? "Switch to Light Mode" : "Switch to Dark Mode",
                systemImage: colorScheme == .dark ? "sun.max" : "moon"
            )
            .labelStyle(.iconOnly)
            .font(.system(size: 12))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(
            colorScheme == .dark
                ? "Switch to light mode (reset to System in Settings › General)"
                : "Switch to dark mode (reset to System in Settings › General)")
    }
}
