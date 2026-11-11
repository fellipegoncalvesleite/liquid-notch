import Foundation
import Sparkle

/// Updates for copies already installed (1.1), through Sparkle, as AirPane does. It reads the appcast attached to the
/// latest GitHub release (`SUFeedURL`) and installs only update files signed with the key in `SUPublicEDKey`
/// (tools/updates.sh). It checks by itself once a day (`SUEnableAutomaticChecks`, so it never asks first); the island's
/// right-click menu has Check for Updates… too. Started only on a normal launch: never for snapshots or tests.
/// A background app (no Dock icon), so it takes Sparkle's gentle reminders: an update found by the daily check waits
/// behind your windows instead of taking focus from what you're doing (Sparkle warns a background app without them).
@MainActor
final class Updates: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkNow() { controller?.checkForUpdates(nil) }
}
