import Foundation

@Observable
final class HealthKitAuthorizationService {
    private let logStore: PhoneLogStore

    var isAuthorizedOnWatch: Bool = false
    var statusMessage: String = "Checking..."

    init(logStore: PhoneLogStore) {
        self.logStore = logStore
        log("HealthKit authorization service initialized")
    }

    func updateFromWatch(authorized: Bool) {
        isAuthorizedOnWatch = authorized
        updateStatusMessage(
            authorized ? "Authorized on Apple Watch" : "Not authorized on Apple Watch"
        )
        log("Watch HealthKit authorization updated: authorized=\(authorized)")
    }

    func updateFromConnectivity(watchPaired: Bool, watchInstalled: Bool, watchReachable: Bool) {
        let nextStatus: String?
        if !watchPaired {
            nextStatus = "No paired Apple Watch"
        } else if !watchInstalled {
            nextStatus = "Apple Watch app not installed"
        } else if !watchReachable {
            nextStatus = "Apple Watch installed, but not reachable"
        } else {
            nextStatus = nil
        }

        if let nextStatus {
            updateStatusMessage(nextStatus)
            log(
                "Watch connectivity status updated: paired=\(watchPaired), installed=\(watchInstalled), reachable=\(watchReachable)"
            )
        }
    }

    private func updateStatusMessage(_ newStatus: String) {
        statusMessage = newStatus
    }

    private func log(_ message: String, level: PhoneLogLevel = .info) {
        logStore.log("HealthKitAuth", message, level: level)
    }
}
