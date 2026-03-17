import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct SmartWakeLogFile: Identifiable, Hashable, Sendable {
    let id: String
    let fileName: String
    let url: URL
    let createdAt: Date
    let modifiedAt: Date
    let sizeInBytes: Int64

    var displayName: String {
        fileName.replacingOccurrences(of: ".log", with: "")
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeInBytes, countStyle: .file)
    }
}

extension SmartWakeLogFile: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { logFile in
            SentTransferredFile(logFile.url)
        }
        .suggestedFileName { logFile in
            logFile.fileName
        }
    }
}

enum SmartWakeLogLevel: String {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

enum SmartWakeLogTransferError: LocalizedError {
    case missingSourceFile(String)

    var errorDescription: String? {
        switch self {
        case .missingSourceFile(let fileName):
            return "The log file \(fileName) no longer exists on the watch."
        }
    }
}

@Observable
final class SmartWakeLogStore {
    private(set) var availableLogs: [SmartWakeLogFile] = []
    private(set) var activeLogFile: SmartWakeLogFile?
    private(set) var runtimeLogFile: SmartWakeLogFile?
    private(set) var lastTransferStatus = "No log transfer yet"
    var runtimeDiagnosticsEnabled = false {
        didSet {
            userDefaults.set(runtimeDiagnosticsEnabled, forKey: runtimeDiagnosticsKey)
        }
    }

    private let fileManager = FileManager.default
    private let userDefaults = UserDefaults.standard
    private let logsDirectoryURL: URL
    private let transferSnapshotsDirectoryURL: URL
    private let transferSnapshotRetentionInterval: TimeInterval = 7 * 24 * 60 * 60
    private let retainedLogLimit = 14
    private let runtimeLogFileName = "smartwake-runtime.log"
    private let runtimeDiagnosticsKey = "smartWakeRuntimeDiagnosticsEnabled"

    private var activeSessionKey: String?
    private var logsDirty = false

    private let logTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        formatter.timeZone = .current
        return formatter
    }()

    private let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmssZ"
        return formatter
    }()

    init() {
        let appSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        logsDirectoryURL = appSupportURL.appendingPathComponent("SmartWakeLogs", isDirectory: true)
        transferSnapshotsDirectoryURL = appSupportURL.appendingPathComponent(
            "SmartWakeLogTransferSnapshots",
            isDirectory: true
        )
        runtimeDiagnosticsEnabled = userDefaults.bool(forKey: runtimeDiagnosticsKey)

        ensureLogsDirectory()
        ensureTransferSnapshotsDirectory()
        pruneTransferSnapshots()
        refreshAvailableLogs()
        log("APP", "SmartWakeLogStore initialized")
    }

    var latestLog: SmartWakeLogFile? {
        availableLogs.first
    }

    var latestSessionLog: SmartWakeLogFile? {
        availableLogs.first(where: { $0.fileName != runtimeLogFileName })
    }

    func prepareSessionLog(
        schedule: WatchScheduleSnapshot,
        wakeUpTime: Date,
        wakeWindowStart: Date,
        reason: String
    ) {
        let sessionKey = makeSessionKey(scheduleID: schedule.id, wakeUpTime: wakeUpTime)
        let logURL = logsDirectoryURL.appendingPathComponent(
            makeFileName(schedule: schedule, wakeUpTime: wakeUpTime)
        )
        let isNewFile = !fileManager.fileExists(atPath: logURL.path)

        activeSessionKey = sessionKey
        if isNewFile {
            let header = [
                "# Lights Timer Watch Smart Wake Log",
                "Created: \(formatTimestamp(Date()))",
                "Schedule: \(schedule.name) (\(schedule.id.uuidString))",
                "Wake Time: \(formatTimestamp(wakeUpTime))",
                "Wake Window Start: \(formatTimestamp(wakeWindowStart))",
                "Lead Time Minutes: \(schedule.leadTimeMinutes)",
                "Smart Wake Window Minutes: \(schedule.smartWakeWindowMinutes)",
                "Target Brightness: \(schedule.targetBrightness)",
                "Skip Color Writes: \(schedule.skipColorWrites)",
                ""
            ].joined(separator: "\n")
            write(header, to: logURL, append: false)
        }

        writeLog(
            category: "SESSION",
            message: "Prepared session log (\(reason)) for '\(schedule.name)' wake=\(formatTimestamp(wakeUpTime)) windowStart=\(formatTimestamp(wakeWindowStart))",
            level: .info,
            logURL: logURL
        )
        logsDirty = true
        refreshAvailableLogs(selecting: logURL)
        pruneLogsIfNeeded(excluding: logURL)
    }

    @discardableResult
    func prepareSessionLogIfNeeded(
        schedule: WatchScheduleSnapshot,
        wakeUpTime: Date,
        wakeWindowStart: Date,
        reason: String
    ) -> Bool {
        let sessionKey = makeSessionKey(scheduleID: schedule.id, wakeUpTime: wakeUpTime)
        guard activeSessionKey != sessionKey else { return false }
        prepareSessionLog(
            schedule: schedule,
            wakeUpTime: wakeUpTime,
            wakeWindowStart: wakeWindowStart,
            reason: reason
        )
        return true
    }

    func log(_ category: String, _ message: String, level: SmartWakeLogLevel = .info) {
        let line = makeLogLine(category: category, message: message, level: level)
        let runtimeURL = logsDirectoryURL.appendingPathComponent(runtimeLogFileName)
        write(line, to: runtimeURL, append: true)

        if let activeLogURL = activeLogFile?.url, activeLogURL != runtimeURL {
            write(line, to: activeLogURL, append: true)
        }

        print(line, terminator: "")
        logsDirty = true
    }

    func latestLogContents() -> String {
        guard let latestLog else { return "No logs recorded yet." }
        return logContents(for: latestLog)
    }

    func logContents(for file: SmartWakeLogFile) -> String {
        (try? String(contentsOf: file.url, encoding: .utf8))
            ?? "Unable to read \(file.fileName)."
    }

    func refreshAvailableLogs() {
        refreshAvailableLogs(selecting: activeLogFile?.url)
    }

    func refreshAvailableLogsIfNeeded() {
        guard logsDirty else { return }
        refreshAvailableLogs(selecting: activeLogFile?.url)
    }

    func noteQueuedTransfer(for fileURL: URL) {
        lastTransferStatus = "Queued \(fileURL.lastPathComponent) for iPhone transfer"
    }

    func noteCompletedTransfer(for fileName: String) {
        lastTransferStatus = "Transferred \(fileName) to iPhone"
    }

    func noteFailedTransfer(for fileName: String, error: String) {
        lastTransferStatus = "Failed to transfer \(fileName): \(error)"
    }

    func prepareTransferSnapshot(for fileURL: URL) throws -> URL {
        ensureTransferSnapshotsDirectory()

        let originalFileName = fileURL.lastPathComponent
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw SmartWakeLogTransferError.missingSourceFile(originalFileName)
        }

        let snapshotURL = transferSnapshotsDirectoryURL.appendingPathComponent(
            "\(UUID().uuidString)-\(originalFileName)"
        )
        try fileManager.copyItem(at: fileURL, to: snapshotURL)
        return snapshotURL
    }

    func cleanupTransferSnapshot(at url: URL) {
        guard url.deletingLastPathComponent() == transferSnapshotsDirectoryURL else { return }
        try? fileManager.removeItem(at: url)
    }

    private func refreshAvailableLogs(selecting selectedURL: URL?) {
        ensureLogsDirectory()

        let logURLs = (try? fileManager.contentsOfDirectory(
            at: logsDirectoryURL,
            includingPropertiesForKeys: [
                .creationDateKey,
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey
            ],
            options: [.skipsHiddenFiles]
        )) ?? []

        let allLogs = logURLs
            .filter { $0.pathExtension == "log" }
            .compactMap(makeLogFile(from:))
            .sorted { lhs, rhs in
                if lhs.modifiedAt == rhs.modifiedAt {
                    return lhs.fileName > rhs.fileName
                }
                return lhs.modifiedAt > rhs.modifiedAt
            }

        runtimeLogFile = allLogs.first(where: { $0.fileName == runtimeLogFileName })
        availableLogs = allLogs.filter { $0.fileName != runtimeLogFileName }

        if let selectedURL {
            activeLogFile = (availableLogs + (runtimeLogFile.map { [$0] } ?? [])).first(where: { $0.url == selectedURL })
        } else if let currentURL = activeLogFile?.url {
            activeLogFile = (availableLogs + (runtimeLogFile.map { [$0] } ?? [])).first(where: { $0.url == currentURL })
        } else {
            activeLogFile = availableLogs.first
        }

        logsDirty = false
    }

    private func pruneLogsIfNeeded(excluding excludedURL: URL) {
        guard availableLogs.count > retainedLogLimit else { return }

        for file in availableLogs.dropFirst(retainedLogLimit) where file.url != excludedURL {
            try? fileManager.removeItem(at: file.url)
        }

        refreshAvailableLogs(selecting: excludedURL)
    }

    private func makeLogFile(from url: URL) -> SmartWakeLogFile? {
        guard let values = try? url.resourceValues(forKeys: [
            .creationDateKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey
        ]),
        values.isRegularFile == true else {
            return nil
        }

        return SmartWakeLogFile(
            id: url.lastPathComponent,
            fileName: url.lastPathComponent,
            url: url,
            createdAt: values.creationDate ?? Date.distantPast,
            modifiedAt: values.contentModificationDate ?? values.creationDate ?? Date.distantPast,
            sizeInBytes: Int64(values.fileSize ?? 0)
        )
    }

    private func ensureLogsDirectory() {
        try? fileManager.createDirectory(
            at: logsDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func ensureTransferSnapshotsDirectory() {
        try? fileManager.createDirectory(
            at: transferSnapshotsDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func pruneTransferSnapshots() {
        let snapshotURLs = (try? fileManager.contentsOfDirectory(
            at: transferSnapshotsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let expirationDate = Date().addingTimeInterval(-transferSnapshotRetentionInterval)

        for snapshotURL in snapshotURLs {
            let values = try? snapshotURL.resourceValues(forKeys: [.contentModificationDateKey])
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            guard modifiedAt < expirationDate else { continue }
            try? fileManager.removeItem(at: snapshotURL)
        }
    }

    private func writeLog(
        category: String,
        message: String,
        level: SmartWakeLogLevel,
        logURL: URL
    ) {
        let line = makeLogLine(category: category, message: message, level: level)
        write(line, to: logURL, append: true)
    }

    private func makeLogLine(
        category: String,
        message: String,
        level: SmartWakeLogLevel
    ) -> String {
        "\(formatTimestamp(Date())) [\(level.rawValue)] [\(category)] \(message)\n"
    }

    private func write(_ string: String, to url: URL, append: Bool) {
        ensureLogsDirectory()

        let data = Data(string.utf8)
        if append {
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil)
            }

            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                return
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func makeSessionKey(scheduleID: UUID, wakeUpTime: Date) -> String {
        "\(scheduleID.uuidString)-\(fileTimestampFormatter.string(from: wakeUpTime))"
    }

    private func makeFileName(schedule: WatchScheduleSnapshot, wakeUpTime: Date) -> String {
        let timestamp = fileTimestampFormatter.string(from: wakeUpTime)
        let safeName = sanitizedFileComponent(schedule.name)
        let shortID = schedule.id.uuidString.prefix(8)
        return "smartwake-\(timestamp)-\(safeName)-\(shortID).log"
    }

    private func sanitizedFileComponent(_ string: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalarView = string.unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(scalar) : "-"
        }
        let collapsed = scalarView.joined()
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return collapsed.isEmpty ? "schedule" : collapsed.lowercased()
    }

    private func formatTimestamp(_ date: Date) -> String {
        logTimestampFormatter.string(from: date)
    }
}
