import Sparkle
import SwiftUI

/// Updates from the GitHub releases through Sparkle: checks on its own once a day and asks before installing
/// (no silent installs). Every update must carry a valid EdDSA signature for `SUPublicEDKey` in Info.plist.
/// Off when the app runs without a packaged Info.plist (swift run), so a dev build never replaces itself.
@MainActor
@Observable
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    private(set) var canCheck = false
    /// Set when a check (scheduled or by hand) found a newer release; shown beside the title.
    private(set) var newVersion: String?

    private override init() {
        super.init()
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["SUFeedURL"] is String, info["SUPublicEDKey"] is String else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller = c
        canCheck = c.updater.canCheckForUpdates
        observation = c.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = can }
        }
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    // SPUUpdaterDelegate is main-actor (NS_SWIFT_UI_ACTOR): Sparkle calls these on the main thread, in order.

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        newVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        newVersion = nil
    }

    /// 跳過此版本: Sparkle will not offer that version again, so the button goes back to 檢查更新. While installing,
    /// a skip may only cancel that install (SPUUserDriver.h), so the button is left for the next check to settle.
    /// 暫緩提醒 and a failed check, download or install leave it as well: the newer version is still there.
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip, state.stage != .installing { newVersion = nil }
    }
}
