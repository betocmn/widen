import AppKit

/// The user's appearance choice, stored under the `"WidenAppearance"`
/// AppStorage key.
public enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public static let storageKey = "WidenAppearance"

    /// The stored preference, or `.system` when unset or invalid.
    public static var stored: AppearancePreference {
        AppearancePreference(
            rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The AppKit appearance to force application-wide; `nil` follows the
    /// system.
    ///
    /// The theme is driven through `NSApplication.appearance` (see ``apply()``)
    /// rather than SwiftUI's `.preferredColorScheme` alone. On macOS that
    /// modifier only overrides the SwiftUI view tree, and the window chrome
    /// plus every `NSVisualEffectView`-backed material (the glass bubbles,
    /// SQL and result cards, toolbar, sidebar) lags behind it — and switching
    /// back to *System* often fails to clear a previously forced window
    /// appearance. Either leaves the content on one appearance and the chrome
    /// on another: the muddy, half-themed colors. Setting the app appearance
    /// repaints every window and material together.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Applies this preference application-wide so every window and its
    /// materials adopt it consistently. Must run on the main thread.
    @MainActor
    public func apply() {
        NSApplication.shared.appearance = nsAppearance
    }
}
