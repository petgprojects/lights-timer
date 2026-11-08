import Foundation
import SwiftData

@Model
final class LightSchedule {
    var id: UUID
    var name: String
    var wakeUpHour: Int
    var wakeUpMinute: Int
    var activeDaysRaw: [Int]
    var leadTimeMinutes: Int
    var targetBrightness: Int
    var startColorHue: Double
    var startColorSaturation: Double
    var startColorBrightness: Double
    var endColorHue: Double
    var endColorSaturation: Double
    var endColorBrightness: Double
    var isEnabled: Bool
    var lightIdentifiers: [String]
    var lightNames: [String]
    var createdAt: Date

    // One-day wake-time change
    var oneDayOverrideOriginalWakeDate: Date?
    var oneDayOverrideWakeDate: Date?

    // Adaptive Lighting
    var startColorIsAdaptive: Bool = false
    var endColorIsAdaptive: Bool = false

    // Smart Wake
    var usesSmartWake: Bool = false
    var smartWakeWindowMinutes: Int = 25
    var hapticPatternRaw: String = "gentle"
    var lastSmartWakeTriggerAt: Date?

    /// When either color is adaptive, all hue/saturation writes are skipped
    /// so that HomeKit Adaptive Lighting stays active on the bulb.
    var skipColorWrites: Bool {
        startColorIsAdaptive || endColorIsAdaptive
    }

    var hapticPattern: HapticPattern {
        get { HapticPattern(rawValue: hapticPatternRaw) ?? .gentle }
        set { hapticPatternRaw = newValue.rawValue }
    }

    var activeDays: Set<DayOfWeek> {
        get {
            Set(activeDaysRaw.compactMap { DayOfWeek(rawValue: $0) })
        }
        set {
            activeDaysRaw = newValue.map(\.rawValue).sorted()
        }
    }

    var wakeUpTimeString: String {
        Self.formatTime(hour: wakeUpHour, minute: wakeUpMinute)
    }

    var activeOneDayOverride: OneDayWakeOverride? {
        oneDayOverride(now: Date())
    }

    var activeDaysSummary: String {
        let days = activeDays.sorted(by: { $0.rawValue < $1.rawValue })
        if days.count == 7 { return "Every day" }
        if days.count == 0 { return "Never" }
        let weekdays: Set<DayOfWeek> = [.monday, .tuesday, .wednesday, .thursday, .friday]
        if days.count == 5 && Set(days) == weekdays { return "Weekdays" }
        let weekends: Set<DayOfWeek> = [.saturday, .sunday]
        if days.count == 2 && Set(days) == weekends { return "Weekends" }
        return days.map(\.shortName).joined(separator: ", ")
    }

    init(
        name: String = "Wake Up",
        wakeUpHour: Int = 7,
        wakeUpMinute: Int = 0,
        activeDays: Set<DayOfWeek> = [.monday, .tuesday, .wednesday, .thursday, .friday],
        leadTimeMinutes: Int = 30,
        targetBrightness: Int = 100,
        startColorHue: Double = 0.08,
        startColorSaturation: Double = 1.0,
        startColorBrightness: Double = 1.0,
        endColorHue: Double = 0.0,
        endColorSaturation: Double = 0.0,
        endColorBrightness: Double = 1.0,
        lightIdentifiers: [String] = [],
        lightNames: [String] = [],
        startColorIsAdaptive: Bool = false,
        endColorIsAdaptive: Bool = false,
        usesSmartWake: Bool = false,
        smartWakeWindowMinutes: Int = 25,
        hapticPatternRaw: String = "gentle"
    ) {
        self.id = UUID()
        self.name = name
        self.wakeUpHour = wakeUpHour
        self.wakeUpMinute = wakeUpMinute
        self.activeDaysRaw = activeDays.map(\.rawValue).sorted()
        self.leadTimeMinutes = leadTimeMinutes
        self.targetBrightness = targetBrightness
        self.startColorHue = startColorHue
        self.startColorSaturation = startColorSaturation
        self.startColorBrightness = startColorBrightness
        self.endColorHue = endColorHue
        self.endColorSaturation = endColorSaturation
        self.endColorBrightness = endColorBrightness
        self.isEnabled = true
        self.lightIdentifiers = lightIdentifiers
        self.lightNames = lightNames
        self.oneDayOverrideOriginalWakeDate = nil
        self.oneDayOverrideWakeDate = nil
        self.startColorIsAdaptive = startColorIsAdaptive
        self.endColorIsAdaptive = endColorIsAdaptive
        self.createdAt = Date()
        self.usesSmartWake = usesSmartWake
        self.smartWakeWindowMinutes = smartWakeWindowMinutes
        self.hapticPatternRaw = hapticPatternRaw
        self.lastSmartWakeTriggerAt = nil
    }

    func nextBaseOccurrence(after date: Date = Date()) -> Date? {
        let calendar = Calendar.current
        let activeDays = activeDays

        guard !activeDays.isEmpty else { return nil }

        for dayOffset in 0..<8 {
            guard let candidateDate = calendar.date(
                byAdding: .day,
                value: dayOffset,
                to: date
            ) else { continue }

            let weekday = calendar.component(.weekday, from: candidateDate)
            guard let dayOfWeek = DayOfWeek(rawValue: weekday),
                  activeDays.contains(dayOfWeek) else { continue }

            var components = calendar.dateComponents([.year, .month, .day], from: candidateDate)
            components.hour = wakeUpHour
            components.minute = wakeUpMinute
            components.second = 0

            guard let wakeDate = calendar.date(from: components), wakeDate > date else {
                continue
            }
            return wakeDate
        }

        return nil
    }

    func oneDayOverride(now: Date) -> OneDayWakeOverride? {
        guard let originalWakeDate = oneDayOverrideOriginalWakeDate,
              let wakeDate = oneDayOverrideWakeDate else { return nil }

        let expirationDate = max(originalWakeDate, wakeDate).addingTimeInterval(5 * 60)
        guard now <= expirationDate else { return nil }

        return OneDayWakeOverride(
            originalWakeDate: originalWakeDate,
            wakeDate: wakeDate
        )
    }

    @discardableResult
    func clearExpiredOneDayOverride(now: Date = Date()) -> Bool {
        guard oneDayOverrideOriginalWakeDate != nil || oneDayOverrideWakeDate != nil else {
            return false
        }
        guard oneDayOverride(now: now) == nil else { return false }

        oneDayOverrideOriginalWakeDate = nil
        oneDayOverrideWakeDate = nil
        return true
    }

    private static func formatTime(hour: Int, minute: Int) -> String {
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        let period = hour < 12 ? "AM" : "PM"
        return String(format: "%d:%02d %@", displayHour, minute, period)
    }
}

struct OneDayWakeOverride: Equatable {
    let originalWakeDate: Date
    let wakeDate: Date
}
