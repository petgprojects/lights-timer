import Foundation

@Observable
final class HealthKitAuthorizationService {
    var isAuthorizedOnWatch: Bool = false
    var statusMessage: String = "Checking..."

    func updateFromWatch(authorized: Bool) {
        isAuthorizedOnWatch = authorized
        statusMessage = authorized ? "Authorized on Apple Watch" : "Not authorized on Apple Watch"
    }

    func updateFromConnectivity(watchInstalled: Bool, watchReachable: Bool) {
        if !watchInstalled {
            statusMessage = "Apple Watch app not installed"
        } else if !watchReachable {
            statusMessage = "Apple Watch not reachable"
        }
    }
}
