import SwiftUI
import SwiftData

struct ScheduleListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ScheduleEngine.self) private var scheduleEngine
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
                }
            }

            ForEach(schedules) { schedule in
                NavigationLink {
                    ScheduleDetailView(scheduleToEdit: schedule)
                } label: {
                    scheduleRow(schedule)
                }
            }
            .onDelete(perform: deleteSchedules)
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
    }
}

#Preview {
    let service = HomeKitService()
    NavigationStack {
        ScheduleListView()
    }
    .modelContainer(for: LightSchedule.self, inMemory: true)
    .environment(service)
    .environment(ScheduleEngine(
        homeKitService: service,
        lightController: LightController(homeKitService: service)
    ))
}
