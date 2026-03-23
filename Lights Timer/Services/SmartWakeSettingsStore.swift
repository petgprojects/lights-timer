import Foundation

@Observable
final class SmartWakeSettingsStore {
    private enum Keys {
        static let powerMode = "smartWakePowerMode"
    }

    private let defaults: UserDefaults
    var onPowerModeChanged: ((SmartWakePowerMode) -> Void)?

    var powerMode: SmartWakePowerMode {
        didSet {
            guard powerMode != oldValue else { return }
            defaults.set(powerMode.rawValue, forKey: Keys.powerMode)
            onPowerModeChanged?(powerMode)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let rawValue = defaults.string(forKey: Keys.powerMode),
           let storedMode = SmartWakePowerMode(rawValue: rawValue) {
            powerMode = storedMode
        } else {
            powerMode = .balanced
        }
    }
}
