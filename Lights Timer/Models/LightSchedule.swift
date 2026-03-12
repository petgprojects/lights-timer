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

    // Smart Wake
    var usesSmartWake: Bool = false
    var smartWakeWindowMinutes: Int = 30
    var hapticPatternRaw: String = "gentle"
    var lastSmartWakeTriggerAt: Date?

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
        let hour = wakeUpHour % 12 == 0 ? 12 : wakeUpHour % 12
        let period = wakeUpHour < 12 ? "AM" : "PM"
        return String(format: "%d:%02d %@", hour, wakeUpMinute, period)
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
        usesSmartWake: Bool = false,
        smartWakeWindowMinutes: Int = 30,
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
        self.createdAt = Date()
        self.usesSmartWake = usesSmartWake
        self.smartWakeWindowMinutes = smartWakeWindowMinutes
        self.hapticPatternRaw = hapticPatternRaw
        self.lastSmartWakeTriggerAt = nil
    }
}
