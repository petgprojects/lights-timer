import SwiftUI

struct DayOfWeekSelector: View {
    @Binding var selectedDays: Set<DayOfWeek>

    var body: some View {
        HStack(spacing: 8) {
            ForEach(DayOfWeek.allCases) { day in
                Button {
                    if selectedDays.contains(day) {
                        selectedDays.remove(day)
                    } else {
                        selectedDays.insert(day)
                    }
                } label: {
                    Text(day.letter)
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(selectedDays.contains(day) ? .white : .secondary)
                        .background {
                            Circle()
                                .fill(selectedDays.contains(day) ? Color.orange : Color(.systemGray5))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.shortName)
                .accessibilityAddTraits(selectedDays.contains(day) ? .isSelected : [])
            }
        }
    }
}

#Preview {
    @Previewable @State var days: Set<DayOfWeek> = [.monday, .wednesday, .friday]
    DayOfWeekSelector(selectedDays: $days)
        .padding()
}
