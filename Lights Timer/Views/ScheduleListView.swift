import SwiftUI
import SwiftData

struct ScheduleListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ScheduleEngine.self) private var scheduleEngine
    @Environment(SmartWakeCoordinator.self) private var smartWakeCoordinator
    @Environment(WatchConnectivityService.self) private var watchConnectivity
    @Query(sort: \LightSchedule.createdAt) private var schedules: [LightSchedule]
    @State private var showingNewSchedule = false

    var body: some View {
        Group {
            if schedules.isEmpty {
                emptyState
            } else {
                scheduleList
            }
        }
        .navigationTitle("Lights Timer")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewSchedule = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewSchedule, onDismiss: syncEngine) {
            NavigationStack {
                ScheduleDetailView()
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Schedules", systemImage: "sunrise")
        } description: {
            Text("Create a wake-up light schedule to get started. Your lights will gradually brighten to help you wake naturally.")
        } actions: {
            Button {
                showingNewSchedule = true
            } label: {
                Text("Add Schedule")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
    }

    private var scheduleList: some View {
        List {
            if scheduleEngine.isSyncing {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                            .tint(.orange)
                        VStack(alignment: .leading) {
                            Text("Syncing to HomeKit…")
                                .font(.subheadline.bold())
                            if scheduleEngine.syncStepsTotal > 0 {
                                Text("\(scheduleEngine.syncStepsCompleted) / \(scheduleEngine.syncStepsTotal) scenes")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if scheduleEngine.syncStepsTotal > 0 {
                            ProgressView(
                                value: Double(scheduleEngine.syncStepsCompleted),
                                total: Double(scheduleEngine.syncStepsTotal)
                            )
                            .frame(width: 60)
                            .tint(.orange)
                        }
                    }
                }
            }

            if scheduleEngine.isRunning, let active = scheduleEngine.activeSchedule {
                Section {
                    HStack {
                        Image(systemName: "sunrise.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading) {
                            Text("Running: \(active.name)")
                                .font(.subheadline.bold())
                            Text("\(Int(scheduleEngine.currentProgress * 100))% complete")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ProgressView(value: scheduleEngine.currentProgress)
                            .frame(width: 60)
                            .tint(.orange)
                    }
                    Button("Stop", role: .destructive) {
                        scheduleEngine.stopForegroundExecution()
                    }
                }
            }

            ForEach(schedules) { schedule in
                NavigationLink {
                    ScheduleDetailView(scheduleToEdit: schedule)
                } label: {
                    scheduleRow(schedule)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        scheduleEngine.startTestExecution(for: schedule)
                    } label: {
                        Label("Test Lights", systemImage: "lightbulb.fill")
                    }
                    .tint(.orange)
                }
            }
            .onDelete(perform: deleteSchedules)

            #if DEBUG
            Section("Smart Wake Debug") {
                LabeledContent("Last Trigger") {
                    Text(smartWakeCoordinator.lastTriggerResult ?? "None")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Light Owner") {
                    Text(smartWakeCoordinator.lastLightRampOwner ?? "None")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Last Scene Sync") {
                    Text(backgroundSyncStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("HomeKit Retry") {
                    Text(scheduleEngine.hasPendingHomeKitRetry ? "Pending" : "Clear")
                        .font(.caption)
                        .foregroundStyle(scheduleEngine.hasPendingHomeKitRetry ? .orange : .secondary)
                }

                HStack {
                    Text("Watch")
                        .font(.caption)
                    Spacer()
                    Image(systemName: watchConnectivity.isWatchReachable ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(watchConnectivity.isWatchReachable ? .green : .red)
                        .imageScale(.small)
                    Text(watchConnectivity.isWatchAppInstalled ? "Installed" : "Not installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            #endif
        }
    }

    private func scheduleRow(_ schedule: LightSchedule) -> some View {
        HStack(spacing: 14) {
            Image(systemName: schedule.isEnabled ? "sunrise.fill" : "sunrise")
                .font(.title2)
                .foregroundStyle(schedule.isEnabled ? .orange : .secondary)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.name)
                    .font(.headline)

                Text(schedule.wakeUpTimeString)
                    .font(.system(.title3, design: .rounded, weight: .medium))
                    .foregroundStyle(schedule.isEnabled ? .primary : .secondary)

                HStack(spacing: 4) {
                    Text(schedule.activeDaysSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !schedule.lightNames.isEmpty {
                        Text("--")
                            .font(.caption)
                            .foregroundStyle(.quaternary)
                        Text(schedule.lightNames.count == 1
                             ? schedule.lightNames[0]
                             : "\(schedule.lightNames.count) lights")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if schedule.usesSmartWake {
                        Text("--")
                            .font(.caption)
                            .foregroundStyle(.quaternary)
                        Label("Smart Wake", systemImage: "applewatch")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { schedule.isEnabled },
                set: { newValue in
                    schedule.isEnabled = newValue
                    syncEngine()
                }
            ))
            .labelsHidden()
            .tint(.orange)
        }
        .padding(.vertical, 4)
    }

    private func deleteSchedules(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(schedules[index])
        }
        syncEngine()
    }

    /// Re-syncs the schedule engine whenever schedules change
    private func syncEngine() {
        Task {
            await scheduleEngine.onAppActive(modelContext: modelContext)
        }
        smartWakeCoordinator.syncSchedulesToWatch(modelContext: modelContext)
    }

    #if DEBUG
    private var backgroundSyncStatus: String {
        if let error = scheduleEngine.lastBackgroundSyncError {
            return error
        }
        if let success = scheduleEngine.lastBackgroundSyncSucceededAt {
            return "Succeeded at \(formatDebugTime(success))"
        }
        if let attempt = scheduleEngine.lastBackgroundSyncAttemptAt {
            return "Attempted at \(formatDebugTime(attempt))"
        }
        return "Not attempted"
    }

    private func formatDebugTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    #endif
}

#Preview {
    let service = HomeKitService()
    let connectivity = WatchConnectivityService()
    let engine = ScheduleEngine(
        homeKitService: service,
        lightController: LightController(homeKitService: service)
    )
    let container = try! ModelContainer(for: LightSchedule.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    NavigationStack {
        ScheduleListView()
    }
    .modelContainer(container)
    .environment(service)
    .environment(engine)
    .environment(SmartWakeCoordinator(scheduleEngine: engine, watchConnectivity: connectivity, modelContainer: container))
    .environment(connectivity)
}
