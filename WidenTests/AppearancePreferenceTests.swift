import AppKit
import Foundation
import Testing

@testable import WidenKit

@Suite("Appearance preference", .serialized)
struct AppearancePreferenceTests {
    private func clearDefaults() {
        UserDefaults.standard.removeObject(forKey: AppearancePreference.storageKey)
    }

    /// The theme is driven through `NSApplication.appearance`, so the AppKit
    /// mapping is what keeps the window chrome and materials in sync with the
    /// content. `nil` for `.system` is what lets switching back to System
    /// hand control to the OS instead of leaving a forced appearance stuck.
    @Test func nsAppearanceMapsToAppKitNames() {
        #expect(AppearancePreference.light.nsAppearance?.name == .aqua)
        #expect(AppearancePreference.dark.nsAppearance?.name == .darkAqua)
        #expect(AppearancePreference.system.nsAppearance == nil)
    }

    @Test func storedReadsAValidSavedPreference() {
        clearDefaults()
        defer { clearDefaults() }

        UserDefaults.standard.set(
            AppearancePreference.dark.rawValue, forKey: AppearancePreference.storageKey)
        #expect(AppearancePreference.stored == .dark)
    }

    @Test func storedFallsBackToSystemWhenUnset() {
        clearDefaults()
        defer { clearDefaults() }

        #expect(AppearancePreference.stored == .system)
    }

    @Test func storedFallsBackToSystemForGarbage() {
        clearDefaults()
        defer { clearDefaults() }

        UserDefaults.standard.set("chartreuse", forKey: AppearancePreference.storageKey)
        #expect(AppearancePreference.stored == .system)
    }
}
