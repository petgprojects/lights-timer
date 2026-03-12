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
    let lightNames: [String]
    var hapticPatternRaw: String

    var wakeUpTimeString: String {
        let hour = wakeUpHour % 12 == 0 ? 12 : wakeUpHour % 12
        let period = wakeUpHour < 12 ? "AM" : "PM"
        return String(format: "%d:%02d %@", hour, wakeUpMinute, period)
    }
}
