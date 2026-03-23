import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(PhoneLogStore.self) private var phoneLogStore
    @Environment(ScheduleEngine.self) private var scheduleEngine
    @Environment(SmartWakeCoordinator.self) private var smartWakeCoordinator
    @Environment(SmartWakeSettingsStore.self) private var smartWakeSettings
    @Environment(WatchConnectivityService.self) private var watchConnectivity
    @Environment(WatchLogArchiveService.self) private var watchLogArchive

    @State private var isPhoneLogsExpanded = false
    @State private var isWatchLogsExpanded = false
    @State private var isSmartWakeDebugExpanded = false

    var body: some View {
        List {
            Section("Smart Wake") {
                Picker("Power Mode", selection: powerModeBinding) {
                    ForEach(SmartWakePowerMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Text(smartWakeSettings.powerMode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(smartWakeSettings.powerMode.detail)
                    .font(.caption)
                    .foregroundStyle(smartWakeSettings.powerMode.isBatteryHeavy ? .orange : .secondary)

                Text("Recommended: add Smart Wake Status to your watch Smart Stack or a complication for the best Balanced-mode reliability. Exact wake still falls back if early smart wake cannot start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: $isPhoneLogsExpanded) {
                phoneLogsContent
            } label: {
                settingsLabel(
                    title: "Phone Logs",
                    systemImage: "iphone"
                )
            }

            DisclosureGroup(isExpanded: $isWatchLogsExpanded) {
                watchLogsContent
            } label: {
                settingsLabel(
                    title: "Watch Logs",
                    systemImage: "applewatch"
                )
            }

            #if DEBUG
            DisclosureGroup(isExpanded: $isSmartWakeDebugExpanded) {
                smartWakeDebugContent
            } label: {
                settingsLabel(
                    title: "Smart Wake Debug",
                    systemImage: "ladybug"
                )
            }
            #endif
        }
        .navigationTitle("Settings")
        .onAppear {
            phoneLogStore.refreshAvailableLogs()
        }
    }

    @ViewBuilder
    private var phoneLogsContent: some View {
        NavigationLink {
            PhoneLogArchiveView()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Saved Phone Logs")
                Text(phoneLogStore.captureStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let runtimeLog = phoneLogStore.runtimeLogFile {
            ShareLink(item: runtimeLog.url) {
                Label("Share Runtime Log", systemImage: "square.and.arrow.up")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(runtimeLog.displayName)
                    .font(.caption)
                Text("\(formatLogDate(runtimeLog.modifiedAt)) • \(runtimeLog.sizeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let latestLaunchLog = phoneLogStore.latestLaunchLog {
            ShareLink(item: latestLaunchLog.url) {
                Label("Share Latest Launch Log", systemImage: "doc.text")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(latestLaunchLog.displayName)
                    .font(.caption)
                Text("\(formatLogDate(latestLaunchLog.modifiedAt)) • \(latestLaunchLog.sizeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("No iPhone launch log has been recorded yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var watchLogsContent: some View {
        NavigationLink {
            WatchLogArchiveView()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Imported Watch Logs")
                Text(watchLogArchive.lastImportStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let latestLog = watchLogArchive.latestLog {
            ShareLink(item: latestLog.url) {
                Label("Share Latest Log", systemImage: "square.and.arrow.up")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(latestLog.displayName)
                    .font(.caption)
                Text("\(formatLogDate(latestLog.modifiedAt)) • \(latestLog.sizeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("No watch log has been imported yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    #if DEBUG
    @ViewBuilder
    private var smartWakeDebugContent: some View {
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
            Image(systemName: watchStatusSymbolName)
                .foregroundStyle(watchStatusColor)
                .imageScale(.small)
            Text(watchStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

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
    #endif

    private func settingsLabel(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
    }

    private func formatLogDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var watchStatusSymbolName: String {
        if watchConnectivity.isWatchReachable {
            return "checkmark.circle.fill"
        }
        if watchConnectivity.effectiveWatchAppInstalled {
            return "exclamationmark.circle.fill"
        }
        return "xmark.circle"
    }

    private var watchStatusColor: Color {
        if watchConnectivity.isWatchReachable {
            return .green
        }
        if watchConnectivity.effectiveWatchAppInstalled {
            return .orange
        }
        return .red
    }

    private var watchStatusText: String {
        if watchConnectivity.isWatchReachable {
            return "Connected"
        }
        if watchConnectivity.effectiveWatchAppInstalled {
            return "Installed, not reachable"
        }
        if watchConnectivity.isWatchPaired {
            return "Not installed"
        }
        return "No paired watch"
    }

    private func formatDebugTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var powerModeBinding: Binding<SmartWakePowerMode> {
        Binding(
            get: { smartWakeSettings.powerMode },
            set: { newValue in smartWakeSettings.powerMode = newValue }
        )
    }
}

#Preview {
    let phoneLogStore = PhoneLogStore()
    let service = HomeKitService(logStore: phoneLogStore)
    let connectivity = WatchConnectivityService(logStore: phoneLogStore)
    let engine = ScheduleEngine(
        homeKitService: service,
        lightController: LightController(
            homeKitService: service,
            logStore: phoneLogStore
        ),
        logStore: phoneLogStore
    )
    let container = try! ModelContainer(
        for: LightSchedule.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let settingsStore = SmartWakeSettingsStore()
    let watchLogArchive = WatchLogArchiveService(logStore: phoneLogStore)

    NavigationStack {
        SettingsView()
    }
    .modelContainer(container)
    .environment(phoneLogStore)
    .environment(service)
    .environment(engine)
    .environment(
        SmartWakeCoordinator(
            scheduleEngine: engine,
            watchConnectivity: connectivity,
            modelContainer: container,
            logStore: phoneLogStore,
            settingsStore: settingsStore
        )
    )
    .environment(settingsStore)
    .environment(connectivity)
    .environment(watchLogArchive)
}
