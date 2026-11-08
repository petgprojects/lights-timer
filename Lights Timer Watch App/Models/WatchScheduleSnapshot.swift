import Foundation

struct WatchScheduleSnapshot: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let wakeUpHour: Int
    let wakeUpMinute: Int
    let activeDaysRaw: [Int]
    let oneDayOverrideOriginalWakeDate: Date?
    let oneDayOverrideWakeDate: Date?
    let leadTimeMinutes: Int
    let usesSmartWake: Bool
    let smartWakeWindowMinutes: Int
    let targetBrightness: Int
    let startColorHue: Double
    let startColorSaturation: Double
    let startColorBrightness: Double
    let endColorHue: Double
    let endColorSaturation: Double
    let endColorBrightness: Double
    let skipColorWrites: Bool
    let lightIdentifiers: [String]
    let lightNames: [String]
    var hapticPatternRaw: String

    var wakeUpTimeString: String {
        let hour = wakeUpHour % 12 == 0 ? 12 : wakeUpHour % 12
        let period = wakeUpHour < 12 ? "AM" : "PM"
        return String(format: "%d:%02d %@", hour, wakeUpMinute, period)
    }

    func oneDayOverride(now: Date) -> (originalWakeDate: Date, wakeDate: Date)? {
        guard let originalWakeDate = oneDayOverrideOriginalWakeDate,
              let wakeDate = oneDayOverrideWakeDate else { return nil }

        let expirationDate = max(originalWakeDate, wakeDate).addingTimeInterval(5 * 60)
        guard now <= expirationDate else { return nil }
        return (originalWakeDate, wakeDate)
    }
}
