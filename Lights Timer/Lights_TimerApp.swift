import SwiftUI
import SwiftData

@main
struct Lights_TimerApp: App {
    let modelContainer: ModelContainer
    @State private var phoneLogStore: PhoneLogStore
    @State private var homeKitService: HomeKitService
    @State private var lightController: LightController
    @State private var scheduleEngine: ScheduleEngine
    @State private var watchConnectivity: WatchConnectivityService
    @State private var smartWakeCoordinator: SmartWakeCoordinator
    @State private var smartWakeSettings: SmartWakeSettingsStore
    @State private var healthKitAuth: HealthKitAuthorizationService
    @State private var watchLogArchive: WatchLogArchiveService

    init() {
        let container = try! ModelContainer(for: LightSchedule.self)
        self.modelContainer = container

        let phoneLogStore = PhoneLogStore()
        let service = HomeKitService(logStore: phoneLogStore)
        let controller = LightController(homeKitService: service, logStore: phoneLogStore)
        let engine = ScheduleEngine(
            homeKitService: service,
            lightController: controller,
            logStore: phoneLogStore
        )
        let smartWakeSettings = SmartWakeSettingsStore()
        let connectivity = WatchConnectivityService(logStore: phoneLogStore)
        let watchLogArchive = WatchLogArchiveService(logStore: phoneLogStore)
        let coordinator = SmartWakeCoordinator(
            scheduleEngine: engine,
            watchConnectivity: connectivity,
            modelContainer: container,
            logStore: phoneLogStore,
            settingsStore: smartWakeSettings
        )
        let healthKitAuth = HealthKitAuthorizationService(logStore: phoneLogStore)

        service.onHomesUpdated = { [weak engine] in
            guard let engine else { return }
            Task { @MainActor in
                let context = ModelContext(container)
                await engine.retryPendingBackgroundSync(modelContext: context)
            }
        }

        _phoneLogStore = State(initialValue: phoneLogStore)
        _homeKitService = State(initialValue: service)
        _lightController = State(initialValue: controller)
        _scheduleEngine = State(initialValue: engine)
        _watchConnectivity = State(initialValue: connectivity)
        _smartWakeCoordinator = State(initialValue: coordinator)
        _smartWakeSettings = State(initialValue: smartWakeSettings)
        _healthKitAuth = State(initialValue: healthKitAuth)
        _watchLogArchive = State(initialValue: watchLogArchive)

        connectivity.onWatchLogFileReceived = { [weak watchLogArchive] fileURL, metadata in
            watchLogArchive?.importTransferredLog(from: fileURL, metadata: metadata)
        }

        smartWakeSettings.onPowerModeChanged = { [weak coordinator] powerMode in
            phoneLogStore.log("APP", "Smart Wake power mode changed to \(powerMode.rawValue)")
            guard let coordinator else { return }
            let context = ModelContext(container)
            coordinator.syncSchedulesToWatch(modelContext: context)
        }

        phoneLogStore.log("APP", "Lights Timer iPhone app initialized")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(phoneLogStore)
                .environment(homeKitService)
                .environment(scheduleEngine)
                .environment(watchConnectivity)
                .environment(smartWakeCoordinator)
                .environment(smartWakeSettings)
                .environment(healthKitAuth)
                .environment(watchLogArchive)
        }
        .modelContainer(modelContainer)
    }
}
