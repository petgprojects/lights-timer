import SwiftUI
import SwiftData

@main
struct Lights_TimerApp: App {
    let modelContainer: ModelContainer
    @State private var homeKitService = HomeKitService()
    @State private var lightController: LightController
    @State private var scheduleEngine: ScheduleEngine
    @State private var watchConnectivity = WatchConnectivityService()
    @State private var smartWakeCoordinator: SmartWakeCoordinator
    @State private var healthKitAuth = HealthKitAuthorizationService()

    init() {
        let container = try! ModelContainer(for: LightSchedule.self)
        self.modelContainer = container

        let service = HomeKitService()
        let controller = LightController(homeKitService: service)
        let engine = ScheduleEngine(homeKitService: service, lightController: controller)
        let connectivity = WatchConnectivityService()
        let coordinator = SmartWakeCoordinator(
            scheduleEngine: engine,
            watchConnectivity: connectivity,
            modelContainer: container
        )

        service.onHomesUpdated = { [weak engine] in
            guard let engine else { return }
            Task { @MainActor in
                let context = ModelContext(container)
                await engine.retryPendingBackgroundSync(modelContext: context)
            }
        }

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
        .modelContainer(modelContainer)
    }
}
