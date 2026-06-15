import Combine
import Sparkle
import SwiftUI
import WidenKit

/// Wraps Sparkle's `SPUStandardUpdaterController` and exposes only what the UI
/// needs. Created once at app launch — which starts the updater and schedules
/// the automatic background checks configured by `SUEnableAutomaticChecks` —
/// then injected into `AppState` so WidenKit's Settings UI can drive it through
/// the `UpdaterControlling` seam without depending on Sparkle.
@MainActor
@Observable
final class UpdaterModel: UpdaterControlling {
    /// Mirrors the Sparkle updater's `canCheckForUpdates` (false only while a
    /// check or install is in flight) so SwiftUI re-renders the menu item and
    /// the Settings button as it flips.
    private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckObserver: AnyCancellable?

    init() {
        // startingUpdater: true launches the scheduled checker; the standard
        // user driver supplies Sparkle's built-in UI — the "new version
        // available" panel, download progress, and the relaunch prompt.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        canCheckObserver = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                // Delivered on the main run loop, so we are on the main actor.
                MainActor.assumeIsolated {
                    self?.canCheckForUpdates = value
                }
            }
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

/// The "Check for Updates…" menu command. A dedicated view so that reading
/// `updater.canCheckForUpdates` in `body` registers SwiftUI observation and the
/// item enables/disables as Sparkle's state changes.
struct CheckForUpdatesView: View {
    var updater: UpdaterModel

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
