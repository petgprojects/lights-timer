import Foundation

struct WatchScheduleSnapshot: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let wakeUpHour: Int
    let wakeUpMinute: Int
    let activeDaysRaw: [Int]
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
}
