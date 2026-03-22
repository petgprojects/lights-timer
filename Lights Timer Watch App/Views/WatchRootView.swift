import SwiftUI
#if os(watchOS)
import WatchKit
#endif

enum WatchRootDestination: Hashable {
    case diagnostics
    case logs
}

struct WatchTopMenu: View {
    @Binding var path: [WatchRootDestination]
    let current: WatchRootDestination?
    @State private var isShowingMenu = false

    var body: some View {
        Button {
            isShowingMenu = true
        } label: {
            Image(systemName: "line.3.horizontal")
        }
        .accessibilityLabel("Open Navigation Menu")
        .confirmationDialog("Navigate", isPresented: $isShowingMenu, titleVisibility: .hidden) {
            if current != nil {
                Button("Main Screen") {
                    path = []
                }
            }

            if current != .diagnostics {
                Button("Diagnostics") {
                    path = [.diagnostics]
                }
            }

            if current != .logs {
                Button("Logs") {
                    path = [.logs]
                }
            }

            Button("Cancel", role: .cancel) {}
        }
    }
}

struct WatchRootView: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(WatchSessionManager.self) private var sessionManager
    @Environment(SmartWakeSessionController.self) private var sessionController
    #if os(watchOS)
    @Environment(SmartWakeLogStore.self) private var logStore
    @Environment(SmartAlarmScheduler.self) private var alarmScheduler
    #endif
    @State private var navigationPath: [WatchRootDestination] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if showsAmbientMonitoringView {
                    ambientMonitoringView
                } else {
                    mainView
                }
            }
            .navigationTitle("Lights Timer")
            .toolbar {
                if !showsAmbientMonitoringView {
                    ToolbarItem(placement: .topBarTrailing) {
                        WatchTopMenu(path: $navigationPath, current: nil)
                    }
                }
            }
            .navigationDestination(for: WatchRootDestination.self) { destination in
                switch destination {
                case .diagnostics:
                    diagnosticsView
                case .logs:
                    WatchLogArchiveView(path: $navigationPath)
                }
            }
        }
    }

    private var mainView: some View {
        @Bindable var sm = sessionManager
        return List {
            statusSection
            schedulesSection(schedules: $sm.activeSchedules)
        }
    }

    private var diagnosticsView: some View {
        List {
            diagnosticsOverviewSection
            #if DEBUG
            spikeDiagnosticsSection
            #endif
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                WatchTopMenu(path: $navigationPath, current: .diagnostics)
            }
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section("Status") {
            HStack {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !sessionController.isHealthKitAuthorized {
                Button("Grant Health Access") {
                    Task {
                        _ = await sessionController.requestAuthorization()
                        sessionManager.sendHeartRateStatus(
                            active: sessionController.hasConfirmedHRAccess
                        )
                        #if os(watchOS)
                        alarmScheduler.onAppForeground()
                        #endif
                    }
                }
                .tint(.orange)
            }
        }
    }

    private func schedulesSection(schedules: Binding<[WatchScheduleSnapshot]>) -> some View {
        Section("Smart Wake Schedules") {
            if sessionManager.activeSchedules.isEmpty {
                Text("No smart wake schedules")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(sessionManager.activeSchedules) { schedule in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(schedule.name)
                                    .font(.headline)
                                Text(schedule.wakeUpTimeString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if sessionController.currentScheduleID == schedule.id {
                                Image(systemName: "waveform.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }

                        Picker(
                            "Haptic",
                            selection: bindingForSchedule(
                                id: schedule.id,
                                defaultPattern: schedule.hapticPatternRaw,
                                schedules: schedules
                            )
                        ) {
                            ForEach(HapticPattern.allCases) { pattern in
                                Text(pattern.displayName).tag(pattern.rawValue)
                            }
                        }
                        .onChange(of: schedule.hapticPatternRaw) { _, newValue in
                            playWatchHapticPreview(for: HapticPattern(rawValue: newValue) ?? .gentle)
                            sessionManager.sendHapticPatternChange(
                                scheduleID: schedule.id,
                                pattern: newValue
                            )
                        }

                        Button {
                            testAlarm(for: schedule)
                        } label: {
                            Label("Test Alarm", systemImage: "play.fill")
                        }
                        .tint(.orange)
                    }
                }
            }
        }
    }

    private func bindingForSchedule(
        id scheduleID: UUID,
        defaultPattern: String,
        schedules: Binding<[WatchScheduleSnapshot]>
    ) -> Binding<String> {
        Binding(
            get: {
                schedules.wrappedValue.first(where: { $0.id == scheduleID })?.hapticPatternRaw
                    ?? defaultPattern
            },
            set: { newValue in
                guard let index = schedules.wrappedValue.firstIndex(where: { $0.id == scheduleID }) else {
                    return
                }
                schedules.wrappedValue[index].hapticPatternRaw = newValue
            }
        )
    }

    private var diagnosticsOverviewSection: some View {
        Section("Diagnostics") {
            if sessionController.sessionState == .monitoring {
                Text(sessionController.heuristicEngine.diagnosticSummary)
                    .font(.caption2)
                    .monospacedDigit()
            }

            #if os(watchOS)
            Toggle("Verbose Diagnostics", isOn: runtimeDiagnosticsBinding)
            #endif

            Text("Includes detailed heart-rate and heuristic logs. Increases file I/O and battery use.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            LabeledContent("Auto-Launch") {
                Text(autoLaunchStatusText)
                    .font(.caption2)
            }

            if let autoLaunchMessage {
                Text(autoLaunchMessage)
                    .font(.caption2)
                    .foregroundStyle(autoLaunchMessageColor)
            }

            #if DEBUG
            if let nextWindow = sessionController.nextScheduledWakeWindowDescription {
                LabeledContent("Next Window") {
                    Text(nextWindow)
                        .font(.caption2)
                }
            }

            LabeledContent("Baseline Ready") {
                Text(sessionController.heuristicEngine.baselineReady ? "Yes" : "No")
                    .font(.caption2)
            }

            LabeledContent("Baseline BPM") {
                Text(sessionController.heuristicEngine.baselineHeartRate.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.caption2)
                    .monospacedDigit()
            }

            LabeledContent("Baseline Samples") {
                Text("\(sessionController.heuristicEngine.baselineSampleCount)")
                    .font(.caption2)
                    .monospacedDigit()
            }

            LabeledContent("Last HR") {
                Text(sessionController.lastHRSampleStatus)
                    .font(.caption2)
                    .monospacedDigit()
            }

            LabeledContent("Phone Ack") {
                Text(sessionController.didReceivePhoneHandoffAck ? sessionController.handoffAckStatus : "Waiting/none")
                    .font(.caption2)
            }

            LabeledContent("Watch Fallback") {
                Text(sessionController.deferredLocalRampStatus)
                    .font(.caption2)
            }
            #endif

            HStack {
                Text("Phone")
                    .font(.caption)
                Spacer()
                Image(systemName: sessionManager.isPhoneReachable ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(sessionManager.isPhoneReachable ? .green : .red)
            }

            HStack {
                Text(workoutSessionLabel)
                    .font(.caption)
                Spacer()
                Image(systemName: sessionController.isWorkoutSessionRunning ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(sessionController.isWorkoutSessionRunning ? .green : .secondary)
            }

            if sessionController.isDegradedMode {
                Text("Degraded mode — no workout session")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text("Background Session")
                    .font(.caption)
                Spacer()
                Image(systemName: sessionController.isAlarmSessionActive ? "checkmark.circle.fill" : "moon.zzz")
                    .foregroundStyle(sessionController.isAlarmSessionActive ? .green : .secondary)
            }

            if let error = sessionController.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            if sessionController.sessionState == .monitoring {
                Button("Stop Monitoring", role: .destructive) {
                    sessionController.stopMonitoring()
                }
            }
        }
    }

    #if DEBUG
    private var spikeDiagnosticsSection: some View {
        Section("Spike Validation") {
            LabeledContent("No-Builder Spike") {
                Text(sessionController.noBuilderValidationStatus)
                    .font(.caption2)
            }

            LabeledContent("Spike Samples") {
                Text("\(sessionController.noBuilderValidationSampleCount)")
                    .font(.caption2)
                    .monospacedDigit()
            }

            LabeledContent("Last Spike Sample") {
                Text(sessionController.noBuilderValidationLastSampleDescription)
                    .font(.caption2)
            }

            LabeledContent("2h Seed Probe") {
                Text(sessionController.noBuilderValidationSeedProbeStatus)
                    .font(.caption2)
            }

            if sessionController.isNoBuilderValidationActive {
                Button("Run 2h Seed Probe") {
                    Task {
                        await sessionController.runNoBuilderValidationSeedProbe()
                    }
                }
                .tint(.orange)

                Button("Stop No-Builder Validation", role: .destructive) {
                    sessionController.stopNoBuilderValidation()
                }
            } else {
                Button("Start No-Builder Validation") {
                    Task {
                        await sessionController.startNoBuilderValidation()
                    }
                }
                .tint(.orange)
            }

            Text("Debug-only spike: starts an HKWorkoutSession without a builder, keeps the anchored heart-rate query running, and logs sample cadence.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
    #endif

    // MARK: - Actions

    private func playWatchHapticPreview(for pattern: HapticPattern) {
        #if os(watchOS)
        let device = WKInterfaceDevice.current()
        switch pattern {
        case .gentle: device.play(.click)
        case .pulse: device.play(.start)
        case .heartbeat: device.play(.directionUp)
        case .alarm: device.play(.notification)
        }
        #endif
    }

    private func testAlarm(for schedule: WatchScheduleSnapshot) {
        // Play haptics on watch
        sessionController.startTestHaptics(
            pattern: HapticPattern(rawValue: schedule.hapticPatternRaw) ?? .gentle
        )
        let lightsHandledOnWatch = sessionController.startTestLights(for: schedule)

        // Notify the phone for status/history, but avoid a duplicate phone-side ramp
        // when the watch already owns the HomeKit writes.
        sessionManager.sendTestTrigger(SmartWakeTriggerPayload(
            scheduleID: schedule.id,
            triggerDate: Date(),
            confidence: 1.0,
            heartRateAtTrigger: nil,
            motionLevel: nil,
            lightsHandledOnWatch: lightsHandledOnWatch ? true : nil
        ))
    }

    // MARK: - Status Helpers

    private var statusIcon: String {
        switch sessionController.sessionState {
        case .idle: "moon.zzz"
        case .monitoring: "waveform.circle.fill"
        case .triggered: "sunrise.fill"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch sessionController.sessionState {
        case .idle: .secondary
        case .monitoring: .green
        case .triggered: .orange
        case .failed: .red
        }
    }

    private var statusTitle: String {
        switch sessionController.sessionState {
        case .idle: "Idle"
        case .monitoring: "Monitoring"
        case .triggered: "Triggered"
        case .failed: "Error"
        }
    }

    private var statusSubtitle: String {
        switch sessionController.sessionState {
        case .idle:
            #if os(watchOS)
            switch alarmScheduler.armingState {
            case .armed(let wakeUpTime, _):
                let suffix = sessionController.isProactiveWorkoutRunning ? " (HR active)" : ""
                return "Smart Wake armed for \(formatTime(wakeUpTime))\(suffix)"
            case .backstopActive(let wakeUpTime):
                return "Recovered Smart Wake backstop active for \(formatTime(wakeUpTime))"
            case .needsForegroundToArm(let wakeUpTime):
                return "Open the watch app to arm Smart Wake for \(formatTime(wakeUpTime))"
            case .tooEarlyToArm(_, let earliestArmingDate):
                return "Too early to arm this wake; reopen after \(formatDateTime(earliestArmingDate))"
            case .noUpcomingWake:
                return "No upcoming smart wake"
            case .failed(let message):
                return message
            case .monitoringNow:
                return "Monitoring start is in progress"
            }
            #else
            return "Smart Wake status unavailable in this build"
            #endif
        case .monitoring:
            return "Watching for wake signals..."
        case .triggered:
            return "Light ramp started!"
        case .failed:
            return sessionController.errorMessage ?? "Unknown error"
        }
    }

    private var workoutSessionLabel: String {
        #if DEBUG
        if sessionController.isNoBuilderValidationActive {
            return "Workout Session (spike)"
        }
        #endif
        if sessionController.isProactiveWorkoutRunning {
            return "Workout Session (overnight)"
        }
        if sessionController.isWorkoutSessionRunning {
            return "Workout Session (monitoring)"
        }
        return "Workout Session"
    }

    #if os(watchOS)
    private var runtimeDiagnosticsBinding: Binding<Bool> {
        Binding(
            get: { logStore.runtimeDiagnosticsEnabled },
            set: { logStore.runtimeDiagnosticsEnabled = $0 }
        )
    }
    #endif

    private var autoLaunchStatusText: String {
        #if os(watchOS)
        switch alarmScheduler.autoLaunchState {
        case .authorized:
            return "Enabled"
        case .notAuthorized:
            return "Off"
        case .unsupported:
            return "Unsupported"
        case .unknown:
            return "Unknown"
        case .failed:
            return "Error"
        }
        #else
        return "Unavailable"
        #endif
    }

    private var autoLaunchMessage: String? {
        #if os(watchOS)
        switch alarmScheduler.autoLaunchState {
        case .notAuthorized:
            return "Reduced resilience: watchOS may not relaunch the app automatically for alarm sessions."
        case .failed(let message):
            return message
        default:
            return nil
        }
        #else
        return nil
        #endif
    }

    private var autoLaunchMessageColor: Color {
        #if os(watchOS)
        switch alarmScheduler.autoLaunchState {
        case .notAuthorized:
            return .orange
        case .failed:
            return .red
        default:
            return .secondary
        }
        #else
        return .secondary
        #endif
    }

    private var currentSessionDescription: String? {
        if let schedule = sessionController.currentSchedule {
            return "\(schedule.name) at \(schedule.wakeUpTimeString)"
        }

        return sessionController.nextScheduledWakeWindowDescription
    }

    private var isAmbientSleepModeActive: Bool {
        sessionController.isProactiveWorkoutRunning
            || sessionController.sessionState == .monitoring
            || sessionController.sessionState == .triggered
    }

    private var showsAmbientMonitoringView: Bool {
        isLuminanceReduced && isAmbientSleepModeActive
    }

    private var ambientMonitoringView: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz.fill")
                .font(.title2)
                .foregroundStyle(.gray)
            Text("Smart Wake Active")
                .font(.caption)
                .foregroundStyle(.gray)
            if let desc = currentSessionDescription {
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    private func formatDateTime(_ date: Date) -> String {
        Self.dateTimeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
