import SwiftUI

final class ScreenIdleTimerManager: Injectable, SettingsObserver {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var broadcaster: Broadcaster!

    private var keepScreenOn: Bool = false

    init(resolver: Resolver) {
        injectServices(resolver)
        keepScreenOn = settingsManager.settings.keepScreenOn
        broadcaster.register(SettingsObserver.self, observer: self)

        Foundation.NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { _ in
            self.updateIdleTimer()
        }

        Foundation.NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { _ in
            self.updateIdleTimer()
        }

        updateIdleTimer()
    }

    func settingsDidChange(_ newSettings: FreeAPSSettings) {
        keepScreenOn = newSettings.keepScreenOn
        updateIdleTimer()
    }

    private func updateIdleTimer() {
        let shouldDisable = keepScreenOn && UIApplication.shared.applicationState == .active
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = shouldDisable
        }
    }
}
