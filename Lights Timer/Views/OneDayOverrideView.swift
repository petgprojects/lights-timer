import SwiftData
import SwiftUI

struct OneDayOverrideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let schedule: LightSchedule

    @State private var changedWakeTime: Date
    @State private var saveError: String?

    private let originalWakeDate: Date?

    init(schedule: LightSchedule) {
        self.schedule = schedule

        let activeOverride = schedule.activeOneDayOverride
        let originalWakeDate = activeOverride?.originalWakeDate
            ?? schedule.nextBaseOccurrence()
        self.originalWakeDate = originalWakeDate
        _changedWakeTime = State(
            initialValue: activeOverride?.wakeDate
                ?? originalWakeDate
                ?? Date()
        )
    }

    var body: some View {
        Form {
            if let originalWakeDate {
                Section {
                    LabeledContent(
                        "Date",
                        value: originalWakeDate.formatted(
                            date: .abbreviated,
                            time: .omitted
                        )
                    )
                    LabeledContent(
                        "Normal Wake Time",
                        value: originalWakeDate.formatted(
                            date: .omitted,
                            time: .shortened
                        )
                    )

                    DatePicker(
                        "Changed Wake Time",
                        selection: $changedWakeTime,
                        displayedComponents: .hourAndMinute
                    )
                } header: {
                    Label("Next Wake", systemImage: "calendar.badge.clock")
                } footer: {
                    Text(
                        "This replaces only the next wake for \(schedule.name). "
                        + "Open Lights Timer once after this wake to restore the normal weekday automation."
                    )
                }

                if schedule.activeOneDayOverride != nil {
                    Section {
                        Button("Cancel One-Day Change", role: .destructive) {
                            cancelOverride()
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No Upcoming Wake", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text("Enable at least one repeat day before setting a one-day change.")
                }
            }
        }
        .navigationTitle("One-Day Change")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveOverride()
                }
                .fontWeight(.semibold)
                .disabled(replacementWakeDate == nil)
            }
        }
        .alert(
            "Couldn’t Save Change",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "Unknown error")
        }
    }

    private var replacementWakeDate: Date? {
        guard let originalWakeDate else { return nil }

        let calendar = Calendar.current
        let timeComponents = calendar.dateComponents([.hour, .minute], from: changedWakeTime)
        var dateComponents = calendar.dateComponents(
            [.year, .month, .day],
            from: originalWakeDate
        )
        dateComponents.hour = timeComponents.hour
        dateComponents.minute = timeComponents.minute
        dateComponents.second = 0

        guard let replacementDate = calendar.date(from: dateComponents),
              replacementDate > Date().addingTimeInterval(60) else {
            return nil
        }
        return replacementDate
    }

    private func saveOverride() {
        guard let originalWakeDate, let replacementWakeDate else { return }

        if replacementWakeDate == originalWakeDate {
            schedule.oneDayOverrideOriginalWakeDate = nil
            schedule.oneDayOverrideWakeDate = nil
        } else {
            schedule.oneDayOverrideOriginalWakeDate = originalWakeDate
            schedule.oneDayOverrideWakeDate = replacementWakeDate
        }
        persistAndDismiss()
    }

    private func cancelOverride() {
        schedule.oneDayOverrideOriginalWakeDate = nil
        schedule.oneDayOverrideWakeDate = nil
        persistAndDismiss()
    }

    private func persistAndDismiss() {
        do {
            try modelContext.save()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

#Preview {
    let schedule = LightSchedule()
    NavigationStack {
        OneDayOverrideView(schedule: schedule)
    }
    .modelContainer(for: LightSchedule.self, inMemory: true)
}
