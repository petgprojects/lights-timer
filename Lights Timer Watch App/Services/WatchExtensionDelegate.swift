#if os(watchOS)
import Foundation
import WatchKit

final class WatchExtensionDelegate: NSObject, WKExtensionDelegate {
    func handle(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        let services = WatchAppServices.shared
        services.logStore.log(
            "SCHEDULER",
            "WKExtensionDelegate received recovered extended runtime session. state=\(extendedRuntimeSession.state.rawValue)"
        )
        services.alarmScheduler.attachRecoveredExtendedRuntimeSession(extendedRuntimeSession)
    }
}
#endif
