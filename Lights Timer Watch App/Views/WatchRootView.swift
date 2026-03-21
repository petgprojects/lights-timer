import SwiftUI
#if os(watchOS)
import WatchKit
#endif

struct WatchRootView: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(SmartWakeLogStore.self) private var logStore
    @Environment(WatchSessionManager.self) private var sessionManager
    @Environment(SmartWakeSessionController.self) private var sessionController
    #if os(watchOS)
    @Environment(SmartAlarmScheduler.self) private var alarmScheduler
    #endif

    var body: some View {
        NavigationStack {
            Group {
                if isLuminanceReduced && isActiveSession {
                    ambientMonitoringView
                } else {
                    fullView
                }
            }
            .navigationTitle("Lights Timer")
        }
    }

    private var fullView: some View {
        @Bindable var sm = sessionManager
        return List {
            statusSection
            schedulesSection(schedules: $sm.activeSchedules)
            diagnosticsSection
            logsSection
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

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            if sessionController.sessionState == .monitoring {
                Text(sessionController.heuristicEngine.diagnosticSummary)
                    .font(.caption2)
                    .monospacedDigit()
            }

            Toggle("Verbose Diagnostics", isOn: runtimeDiagnosticsBinding)

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

            #if DEBUG
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
            #endif

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

    private var logsSection: some View {
        Section("Logs") {
            NavigationLink("Open Watch Logs") {
                WatchLogArchiveView()
            }

            if let runtimeLog = logStore.runtimeLogFile {
                ShareLink(item: runtimeLog, preview: SharePreview(runtimeLog.fileName)) {
                    Label("Share Runtime Log", systemImage: "square.and.arrow.up")
                }

                Button {
                    sessionManager.transferLogFile(runtimeLog.url)
                } label: {
                    Label("Send Runtime Log To iPhone", systemImage: "iphone")
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(runtimeLog.displayName)
                        .font(.caption2)
                    Text("\(formatLogDate(runtimeLog.modifiedAt)) • \(runtimeLog.sizeDescription)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No watch logs yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let latestSessionLog = logStore.latestSessionLog {
                ShareLink(item: latestSessionLog, preview: SharePreview(latestSessionLog.fileName)) {
                    Label("Share Latest Session Log", systemImage: "doc.text")
                }

                Button {
                    sessionManager.transferLogFile(latestSessionLog.url)
                } label: {
                    Label("Send Session Log To iPhone", systemImage: "iphone.gen3")
                }
            }

            LabeledContent("iPhone Export") {
                Text(logStore.lastTransferStatus)
                    .font(.caption2)
            }
        }
        .onAppear {
            logStore.refreshAvailableLogsIfNeeded()
        }
    }

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

    private var runtimeDiagnosticsBinding: Binding<Bool> {
        Binding(
            get: { logStore.runtimeDiagnosticsEnabled },
            set: { logStore.runtimeDiagnosticsEnabled = $0 }
        )
    }

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
        guard let schedule = sessionController.currentSchedule else { return nil }
        return "\(schedule.name) at \(schedule.wakeUpTimeString)"
    }

    private var isActiveSession: Bool {
        sessionController.sessionState == .monitoring || sessionController.sessionState == .triggered
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

    private func formatLogDate(_ date: Date) -> String {
        Self.logDateFormatter.string(from: date)
    }

    private func formatTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    private func formatDateTime(_ date: Date) -> String {
        Self.dateTimeFormatter.string(from: date)
    }

    private static let logDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

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
