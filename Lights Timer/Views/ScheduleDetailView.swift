import SwiftUI
import SwiftData
import UIKit

struct ScheduleDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(ScheduleEngine.self) private var scheduleEngine

    var scheduleToEdit: LightSchedule?

    @State private var name: String = "Wake Up"
    @State private var wakeUpTime: Date = Calendar.current.date(
        from: DateComponents(hour: 7, minute: 0)
    ) ?? .now
    @State private var activeDays: Set<DayOfWeek> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    @State private var leadTimeMinutes: Int = 30
    @State private var targetBrightness: Int = 100
    @State private var startHue: Double = 0.08
    @State private var startSaturation: Double = 1.0
    @State private var startBrightness: Double = 1.0
    @State private var endHue: Double = 0.0
    @State private var endSaturation: Double = 0.0
    @State private var endBrightness: Double = 1.0
    @State private var startColorIsAdaptive: Bool = false
    @State private var endColorIsAdaptive: Bool = false
    @State private var lightIdentifiers: [String] = []
    @State private var lightNames: [String] = []
    @State private var usesSmartWake: Bool = false
    @State private var smartWakeWindowMinutes: Int = 30
    @State private var hapticPattern: HapticPattern = .gentle
    @State private var isSaving: Bool = false

    private var isEditing: Bool { scheduleToEdit != nil }

    var body: some View {
        Form {
            nameSection
            timeSection
            daysSection
            lightsSection
            leadTimeSection
            smartWakeSection
            brightnessSection
            ColorPreferenceView(
                startHue: $startHue,
                startSaturation: $startSaturation,
                startBrightness: $startBrightness,
                endHue: $endHue,
                endSaturation: $endSaturation,
                endBrightness: $endBrightness,
                startIsAdaptive: $startColorIsAdaptive,
                endIsAdaptive: $endColorIsAdaptive
            )
        }
        .navigationTitle(isEditing ? "Edit Schedule" : "New Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    isSaving = true
                    save()
                    Task {
                        await scheduleEngine.onAppActive(modelContext: modelContext)
                        isSaving = false
                        dismiss()
                    }
                }
                .fontWeight(.semibold)
                .disabled(isSaving)
            }
            if !isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
            }
        }
        .overlay {
            if isSaving {
                syncOverlay
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            if let schedule = scheduleToEdit {
                populateFromSchedule(schedule)
            }
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section {
            TextField("Schedule Name", text: $name)
        } header: {
            Label("Name", systemImage: "pencil")
        }
    }

    private var timeSection: some View {
        Section {
            DatePicker(
                "Wake Up Time",
                selection: $wakeUpTime,
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        } header: {
            Label("Wake Up Time", systemImage: "sunrise.fill")
        }
    }

    private var daysSection: some View {
        Section {
            DayOfWeekSelector(selectedDays: $activeDays)
                .frame(maxWidth: .infinity)
        } header: {
            Label("Repeat", systemImage: "calendar")
        }
    }

    private var lightsSection: some View {
        Section {
            NavigationLink {
                LightPickerView(
                    selectedIdentifiers: $lightIdentifiers,
                    selectedNames: $lightNames
                )
            } label: {
                HStack {
                    Label("Lights", systemImage: "lightbulb.fill")
                    Spacer()
                    if lightNames.isEmpty {
                        Text("None")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(lightNames.count == 1 ? lightNames[0] : "\(lightNames.count) lights")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var leadTimeSection: some View {
        Section {
            Stepper(
                "\(leadTimeMinutes) minutes",
                value: $leadTimeMinutes,
                in: 5...120,
                step: 5
            )
        } header: {
            Label("Lead Time", systemImage: "timer")
        } footer: {
            Text("How long before wake-up the lights start turning on.")
        }
    }

    private var smartWakeSection: some View {
        Section {
            Toggle(isOn: $usesSmartWake) {
                Label("Smart Wake", systemImage: "applewatch")
            }
            .tint(.orange)

            if usesSmartWake {
                Stepper(
                    "\(smartWakeWindowMinutes) min window",
                    value: $smartWakeWindowMinutes,
                    in: 10...60,
                    step: 5
                )

                Picker(selection: $hapticPattern) {
                    ForEach(HapticPattern.allCases) { pattern in
                        Label {
                            VStack(alignment: .leading) {
                                Text(pattern.displayName)
                                Text(pattern.patternDescription)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: pattern.systemImage)
                        }
                        .tag(pattern)
                    }
                } label: {
                    Label("Haptic Style", systemImage: "waveform")
                }
                .onChange(of: hapticPattern) { _, newPattern in
                    playHapticPreview(for: newPattern)
                }
            }
        } header: {
            Label("Apple Watch", systemImage: "applewatch")
        } footer: {
            if usesSmartWake {
                Text("When the watch detects you're waking up, lights ramp to full brightness in ~1 minute while haptic taps on your wrist escalate to wake you. Falls back to scheduled time if the watch is unavailable.")
            } else {
                Text("Enable to use Apple Watch sensors to find the ideal wake moment.")
            }
        }
    }

    private var brightnessSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Brightness")
                    Spacer()
                    Text("\(targetBrightness)%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 10) {
                    Image(systemName: "sun.min")
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(targetBrightness) },
                            set: { targetBrightness = Int($0) }
                        ),
                        in: 0...100,
                        step: 5
                    )
                    .tint(.orange)
                    Image(systemName: "sun.max.fill")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Label("Target Brightness", systemImage: "sun.max")
        }
    }

    // MARK: - Sync Overlay

    private var syncOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.orange)

                Text("Syncing to HomeKit…")
                    .font(.headline)

                if scheduleEngine.syncStepsTotal > 0 {
                    ProgressView(
                        value: Double(scheduleEngine.syncStepsCompleted),
                        total: Double(scheduleEngine.syncStepsTotal)
                    )
                    .tint(.orange)
                    .frame(width: 200)

                    Text("\(scheduleEngine.syncStepsCompleted) / \(scheduleEngine.syncStepsTotal) scenes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Actions

    private func populateFromSchedule(_ schedule: LightSchedule) {
        name = schedule.name
        let components = DateComponents(hour: schedule.wakeUpHour, minute: schedule.wakeUpMinute)
        wakeUpTime = Calendar.current.date(from: components) ?? .now
        activeDays = schedule.activeDays
        leadTimeMinutes = schedule.leadTimeMinutes
        targetBrightness = schedule.targetBrightness
        startHue = schedule.startColorHue
        startSaturation = schedule.startColorSaturation
        startBrightness = schedule.startColorBrightness
        endHue = schedule.endColorHue
        endSaturation = schedule.endColorSaturation
        endBrightness = schedule.endColorBrightness
        lightIdentifiers = schedule.lightIdentifiers
        lightNames = schedule.lightNames
        startColorIsAdaptive = schedule.startColorIsAdaptive
        endColorIsAdaptive = schedule.endColorIsAdaptive
        usesSmartWake = schedule.usesSmartWake
        smartWakeWindowMinutes = schedule.smartWakeWindowMinutes
        hapticPattern = schedule.hapticPattern
    }

    private func playHapticPreview(for pattern: HapticPattern) {
        switch pattern {
        case .gentle:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .pulse:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heartbeat:
            let generator = UIImpactFeedbackGenerator(style: .rigid)
            generator.impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                generator.impactOccurred(intensity: 0.5)
            }
        case .alarm:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    private func save() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: wakeUpTime)
        let hour = components.hour ?? 7
        let minute = components.minute ?? 0

        if let schedule = scheduleToEdit {
            schedule.name = name
            schedule.wakeUpHour = hour
            schedule.wakeUpMinute = minute
            schedule.activeDays = activeDays
            schedule.leadTimeMinutes = leadTimeMinutes
            schedule.targetBrightness = targetBrightness
            schedule.startColorHue = startHue
            schedule.startColorSaturation = startSaturation
            schedule.startColorBrightness = startBrightness
            schedule.endColorHue = endHue
            schedule.endColorSaturation = endSaturation
            schedule.endColorBrightness = endBrightness
            schedule.lightIdentifiers = lightIdentifiers
            schedule.lightNames = lightNames
            schedule.startColorIsAdaptive = startColorIsAdaptive
            schedule.endColorIsAdaptive = endColorIsAdaptive
            schedule.usesSmartWake = usesSmartWake
            schedule.smartWakeWindowMinutes = smartWakeWindowMinutes
            schedule.hapticPatternRaw = hapticPattern.rawValue
        } else {
            let schedule = LightSchedule(
                name: name,
                wakeUpHour: hour,
                wakeUpMinute: minute,
                activeDays: activeDays,
                leadTimeMinutes: leadTimeMinutes,
                targetBrightness: targetBrightness,
                startColorHue: startHue,
                startColorSaturation: startSaturation,
                startColorBrightness: startBrightness,
                endColorHue: endHue,
                endColorSaturation: endSaturation,
                endColorBrightness: endBrightness,
                lightIdentifiers: lightIdentifiers,
                lightNames: lightNames,
                startColorIsAdaptive: startColorIsAdaptive,
                endColorIsAdaptive: endColorIsAdaptive,
                usesSmartWake: usesSmartWake,
                smartWakeWindowMinutes: smartWakeWindowMinutes,
                hapticPatternRaw: hapticPattern.rawValue
            )
            modelContext.insert(schedule)
        }
    }
}

#Preview("Create") {
    let phoneLogStore = PhoneLogStore()
    NavigationStack {
        ScheduleDetailView()
    }
    .modelContainer(for: LightSchedule.self, inMemory: true)
    .environment(phoneLogStore)
    .environment(HomeKitService(logStore: phoneLogStore))
}
