import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(ScheduleEngine.self) private var scheduleEngine

    var body: some View {
        NavigationStack {
            ScheduleListView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await scheduleEngine.onAppActive(modelContext: modelContext)
                }
            }
        }
    }
}
