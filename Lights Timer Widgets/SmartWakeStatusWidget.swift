import SwiftUI
import WidgetKit

private let smartWakeWidgetKind = "com.PeterGelgor.Lights-Timer.smartwake.status"

struct SmartWakeWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: SmartWakeWidgetSnapshot
}

struct SmartWakeTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> SmartWakeWidgetEntry {
        SmartWakeWidgetEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SmartWakeWidgetEntry) -> Void) {
        let snapshot = context.isPreview ? SmartWakeWidgetSnapshot.placeholder : SmartWakeSharedStore.loadWidgetSnapshot()
        completion(SmartWakeWidgetEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SmartWakeWidgetEntry>) -> Void) {
        let entry = SmartWakeWidgetEntry(date: .now, snapshot: SmartWakeSharedStore.loadWidgetSnapshot())
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(refreshDate)))
    }
}

struct SmartWakeWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family

    let entry: SmartWakeWidgetEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circularView
        case .accessoryInline:
            inlineView
        default:
            rectangularView
        }
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: statusIconName)
                    .foregroundStyle(statusColor)
                Text(entry.snapshot.statusTitle)
                    .font(.headline)
                    .lineLimit(1)
            }

            Text(entry.snapshot.nextWakeText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(entry.snapshot.statusDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 4) {
                Text(entry.snapshot.powerModeDisplayName)
                    .font(.caption2.weight(.semibold))
                if entry.snapshot.isBatteryHeavy {
                    Image(systemName: "battery.25")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var circularView: some View {
        VStack(spacing: 2) {
            Image(systemName: statusIconName)
                .font(.headline)
                .foregroundStyle(statusColor)
            Text(circularLabel)
                .font(.system(size: 9, weight: .semibold))
                .minimumScaleFactor(0.7)
        }
    }

    private var inlineView: some View {
        Text("\(entry.snapshot.statusTitle) • \(entry.snapshot.nextWakeText)")
    }

    private var statusIconName: String {
        let title = entry.snapshot.statusTitle.lowercased()
        if title.contains("monitoring") {
            return "waveform.path.ecg"
        }
        if title.contains("fallback") {
            return "lightbulb.max"
        }
        if title.contains("failed") {
            return "exclamationmark.triangle"
        }
        if title.contains("no wake") {
            return "bed.double"
        }
        return "alarm"
    }

    private var statusColor: Color {
        let title = entry.snapshot.statusTitle.lowercased()
        if title.contains("monitoring") {
            return .green
        }
        if title.contains("fallback") {
            return .yellow
        }
        if title.contains("failed") {
            return .red
        }
        if entry.snapshot.isBatteryHeavy {
            return .orange
        }
        return .blue
    }

    private var circularLabel: String {
        let title = entry.snapshot.statusTitle.lowercased()
        if title.contains("monitoring") {
            return "Live"
        }
        if title.contains("fallback") {
            return "Back"
        }
        if title.contains("failed") {
            return "Fail"
        }
        if title.contains("no wake") {
            return "Idle"
        }
        return "Armed"
    }
}

struct SmartWakeStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: smartWakeWidgetKind, provider: SmartWakeTimelineProvider()) { entry in
            SmartWakeWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Smart Wake Status")
        .description("Shows the next smart wake and whether monitoring or fallback is active.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryInline,
            .accessoryRectangular,
        ])
    }
}

#Preview(as: .accessoryRectangular) {
    SmartWakeStatusWidget()
} timeline: {
    SmartWakeWidgetEntry(date: .now, snapshot: .placeholder)
    SmartWakeWidgetEntry(
        date: .now,
        snapshot: SmartWakeWidgetSnapshot(
            statusTitle: "Monitoring Now",
            statusDetail: "Workout-backed monitoring is active for this wake window.",
            nextWakeText: "Next wake 7:00 AM",
            powerModeDisplayName: "High Reliability",
            powerModeDescription: "Highest chance of early smart wake, higher battery use.",
            isBatteryHeavy: true,
            updatedAt: .now
        )
    )
}
