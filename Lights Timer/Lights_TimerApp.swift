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
    @State private var watchLogArchive: WatchLogArchiveService

    init() {
        let container = try! ModelContainer(for: LightSchedule.self)
        self.modelContainer = container

        let service = HomeKitService()
        let controller = LightController(homeKitService: service)
        let engine = ScheduleEngine(homeKitService: service, lightController: controller)
        let connectivity = WatchConnectivityService()
        let watchLogArchive = WatchLogArchiveService()
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
        _watchLogArchive = State(initialValue: watchLogArchive)

        connectivity.onWatchLogFileReceived = { [weak watchLogArchive] fileURL, metadata in
            watchLogArchive?.importTransferredLog(from: fileURL, metadata: metadata)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(homeKitService)
                .environment(scheduleEngine)
                .environment(watchConnectivity)
                .environment(smartWakeCoordinator)
                .environment(healthKitAuth)
                .environment(watchLogArchive)
        }
        .modelContainer(modelContainer)
    }
}
