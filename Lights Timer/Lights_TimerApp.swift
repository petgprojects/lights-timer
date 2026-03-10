import SwiftUI
import SwiftData

@main
struct Lights_TimerApp: App {
    @State private var homeKitService = HomeKitService()
    @State private var lightController: LightController
    @State private var scheduleEngine: ScheduleEngine

    init() {
        let service = HomeKitService()
        let controller = LightController(homeKitService: service)
        let engine = ScheduleEngine(homeKitService: service, lightController: controller)
        _homeKitService = State(initialValue: service)
        _lightController = State(initialValue: controller)
        _scheduleEngine = State(initialValue: engine)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(homeKitService)
                .environment(scheduleEngine)
        }
        .modelContainer(for: LightSchedule.self)
    }
}
