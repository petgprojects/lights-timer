import SwiftUI
#if os(watchOS)
import WatchKit
#endif

struct WatchRootView: View {
    @Environment(WatchSessionManager.self) private var sessionManager
    @Environment(SmartWakeSessionController.self) private var sessionController

    var body: some View {
        @Bindable var sm = sessionManager
        NavigationStack {
            List {
                statusSection
                schedulesSection(schedules: $sm.activeSchedules)
                diagnosticsSection
            }
            .navigationTitle("Lights Timer")
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
                        await sessionController.requestAuthorization()
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
            if let next = nextScheduleDescription {
                return "Next: \(next)"
            }
            return "No upcoming smart wake"
        case .monitoring:
            return "Watching for wake signals..."
        case .triggered:
            return "Light ramp started!"
        case .failed:
            return sessionController.errorMessage ?? "Unknown error"
        }
    }

    private var nextScheduleDescription: String? {
        guard let schedule = sessionManager.activeSchedules.first else { return nil }
        return "\(schedule.name) at \(schedule.wakeUpTimeString)"
    }
}
