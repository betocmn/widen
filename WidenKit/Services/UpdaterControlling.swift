import Foundation

/// A thin seam over the app's updater so WidenKit's Settings UI can drive
/// "check for updates" and the auto-check preference without depending on
/// Sparkle. The app provides the concrete implementation (which wraps
/// `SPUStandardUpdaterController`) and injects it via `AppState.updaterControl`.
@MainActor
public protocol UpdaterControlling: AnyObject {
    /// True when the app bundle has enough updater configuration to start
    /// Sparkle. Public source builds leave this false until release values are
    /// injected.
    var isConfigured: Bool { get }

    /// Whether an update check can be started right now (false while a check
    /// or install is already in flight). Drives the menu/button enabled state.
    var canCheckForUpdates: Bool { get }

    /// The user's "automatically check for updates" preference. Persisted by
    /// the updater itself.
    var automaticallyChecksForUpdates: Bool { get set }

    /// Starts a user-initiated update check, showing Sparkle's standard UI.
    func checkForUpdates()
}
