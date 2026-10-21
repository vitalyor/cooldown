import Foundation
import Intents

/// Whether a macOS Focus (Do Not Disturb, Sleep, Work…) is on. macOS tells an app only that a
/// Focus is on, not which one, and only after the person allows it once.
enum FocusWatch {
    static func start() {
        let center = INFocusStatusCenter.default
        if center.authorizationStatus == .notDetermined {
            center.requestAuthorization { _ in }
        }
    }

    static var isFocused: Bool {
        let center = INFocusStatusCenter.default
        guard center.authorizationStatus == .authorized else { return false }
        return center.focusStatus.isFocused ?? false
    }
}
