import SwiftUI
import SwiftData

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
    @State private var lightIdentifiers: [String] = []
    @State private var lightNames: [String] = []

    private var isEditing: Bool { scheduleToEdit != nil }

    var body: some View {
        Form {
            nameSection
            timeSection
            daysSection
            lightsSection
            leadTimeSection
            brightnessSection
            ColorPreferenceView(
                startHue: $startHue,
                startSaturation: $startSaturation,
                startBrightness: $startBrightness,
                endHue: $endHue,
                endSaturation: $endSaturation,
                endBrightness: $endBrightness
            )
        }
        .navigationTitle(isEditing ? "Edit Schedule" : "New Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                    Task {
                        await scheduleEngine.onAppActive(modelContext: modelContext)
                    }
                    dismiss()
                }
                .fontWeight(.semibold)
            }
            if !isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
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
                lightNames: lightNames
            )
            modelContext.insert(schedule)
        }
    }
}

#Preview("Create") {
    NavigationStack {
        ScheduleDetailView()
    }
    .modelContainer(for: LightSchedule.self, inMemory: true)
    .environment(HomeKitService())
}
