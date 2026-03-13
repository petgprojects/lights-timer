import Foundation

struct PhoneLogFile: Identifiable, Hashable {
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

enum PhoneLogLevel: String {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

@Observable
final class PhoneLogStore {
    private(set) var availableLaunchLogs: [PhoneLogFile] = []
    private(set) var activeLaunchLogFile: PhoneLogFile?
    private(set) var runtimeLogFile: PhoneLogFile?
    private(set) var captureStatus = "Preparing iPhone log capture"

    private let fileManager = FileManager.default
    private let logsDirectoryURL: URL
    private let retainedLaunchLogLimit = 14
    private let runtimeLogFileName = "iphone-runtime.log"

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
        logsDirectoryURL = appSupportURL.appendingPathComponent("PhoneLogs", isDirectory: true)

        ensureLogsDirectory()
        ensureRuntimeLogExists()
        startLaunchLog(reason: "app-launch")
        refreshAvailableLogs()
        log("APP", "PhoneLogStore initialized")
    }

    var latestLaunchLog: PhoneLogFile? {
        availableLaunchLogs.first
    }

    func log(_ category: String, _ message: String, level: PhoneLogLevel = .info) {
        ensureLogsDirectory()
        ensureRuntimeLogExists()

        let line = makeLogLine(category: category, message: message, level: level)
        let runtimeURL = logsDirectoryURL.appendingPathComponent(runtimeLogFileName)
        write(line, to: runtimeURL, append: true)

        if let launchURL = activeLaunchLogFile?.url {
            write(line, to: launchURL, append: true)
        }

        print(line, terminator: "")
        refreshAvailableLogs(selecting: activeLaunchLogFile?.url)
    }

    func logContents(for file: PhoneLogFile) -> String {
        (try? String(contentsOf: file.url, encoding: .utf8))
            ?? "Unable to read \(file.fileName)."
    }

    func refreshAvailableLogs() {
        refreshAvailableLogs(selecting: activeLaunchLogFile?.url)
    }

    private func startLaunchLog(reason: String) {
        let launchDate = Date()
        let launchURL = logsDirectoryURL.appendingPathComponent(
            makeLaunchFileName(for: launchDate)
        )
        let runtimeURL = logsDirectoryURL.appendingPathComponent(runtimeLogFileName)

        let header = [
            "# Lights Timer iPhone Launch Log",
            "Created: \(formatTimestamp(launchDate))",
            "Reason: \(reason)",
            "App Version: \(appVersionDescription())",
            ""
        ].joined(separator: "\n")
        write(header, to: launchURL, append: false)

        let runtimeMarker = [
            "",
            "## App Launch",
            "Started: \(formatTimestamp(launchDate))",
            "Reason: \(reason)",
            "App Version: \(appVersionDescription())",
            ""
        ].joined(separator: "\n")
        write(runtimeMarker, to: runtimeURL, append: true)

        refreshAvailableLogs(selecting: launchURL)
        pruneLogsIfNeeded(excluding: launchURL)

        captureStatus = "Recording to \(runtimeLogFileName) and \(launchURL.lastPathComponent)"
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
        availableLaunchLogs = allLogs.filter { $0.fileName != runtimeLogFileName }

        if let selectedURL,
           selectedURL.lastPathComponent != runtimeLogFileName {
            activeLaunchLogFile = availableLaunchLogs.first(where: { $0.url == selectedURL })
        } else if let currentURL = activeLaunchLogFile?.url {
            activeLaunchLogFile = availableLaunchLogs.first(where: { $0.url == currentURL })
        } else {
            activeLaunchLogFile = availableLaunchLogs.first
        }
    }

    private func pruneLogsIfNeeded(excluding excludedURL: URL) {
        guard availableLaunchLogs.count > retainedLaunchLogLimit else { return }

        for file in availableLaunchLogs.dropFirst(retainedLaunchLogLimit) where file.url != excludedURL {
            try? fileManager.removeItem(at: file.url)
        }

        refreshAvailableLogs(selecting: excludedURL)
    }

    private func ensureRuntimeLogExists() {
        let runtimeURL = logsDirectoryURL.appendingPathComponent(runtimeLogFileName)
        guard !fileManager.fileExists(atPath: runtimeURL.path) else { return }

        let header = [
            "# Lights Timer iPhone Runtime Log",
            "Created: \(formatTimestamp(Date()))",
            "App Version: \(appVersionDescription())",
            ""
        ].joined(separator: "\n")
        write(header, to: runtimeURL, append: false)
    }

    private func makeLogFile(from url: URL) -> PhoneLogFile? {
        guard let values = try? url.resourceValues(forKeys: [
            .creationDateKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey
        ]),
        values.isRegularFile == true else {
            return nil
        }

        return PhoneLogFile(
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

    private func makeLogLine(
        category: String,
        message: String,
        level: PhoneLogLevel
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

    private func makeLaunchFileName(for date: Date) -> String {
        "iphone-launch-\(fileTimestampFormatter.string(from: date)).log"
    }

    private func appVersionDescription() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (version?, build?):
            return "\(version) (\(build))"
        case let (version?, nil):
            return version
        case let (nil, build?):
            return build
        case (nil, nil):
            return "Unknown"
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        logTimestampFormatter.string(from: date)
    }
}
