import SwiftUI
import SwiftData

@main
struct Lights_TimerApp: App {
    @State private var homeKitService = HomeKitService()
    @State private var lightController: LightController
    @State private var scheduleEngine: ScheduleEngine
    @State private var watchConnectivity = WatchConnectivityService()
    @State private var smartWakeCoordinator: SmartWakeCoordinator
    @State private var healthKitAuth = HealthKitAuthorizationService()

    init() {
        let service = HomeKitService()
        let controller = LightController(homeKitService: service)
        let engine = ScheduleEngine(homeKitService: service, lightController: controller)
        let connectivity = WatchConnectivityService()
        let coordinator = SmartWakeCoordinator(
            scheduleEngine: engine,
            watchConnectivity: connectivity
        )

        _homeKitService = State(initialValue: service)
        _lightController = State(initialValue: controller)
        _scheduleEngine = State(initialValue: engine)
        _watchConnectivity = State(initialValue: connectivity)
        _smartWakeCoordinator = State(initialValue: coordinator)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(homeKitService)
                .environment(scheduleEngine)
                .environment(watchConnectivity)
                .environment(smartWakeCoordinator)
                .environment(healthKitAuth)
        }
        .modelContainer(for: LightSchedule.self)
    }
}
