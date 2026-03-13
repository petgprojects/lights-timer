import Foundation

struct ImportedWatchLogFile: Identifiable, Hashable {
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

@Observable
final class WatchLogArchiveService {
    private(set) var importedLogs: [ImportedWatchLogFile] = []
    private(set) var lastImportStatus = "No watch logs imported yet"

    private let fileManager = FileManager.default
    private let logsDirectoryURL: URL

    init() {
        let appSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        logsDirectoryURL = appSupportURL.appendingPathComponent("ImportedWatchLogs", isDirectory: true)

        ensureLogsDirectory()
        refreshImportedLogs()
    }

    var latestLog: ImportedWatchLogFile? {
        importedLogs.first
    }

    func importTransferredLog(from temporaryURL: URL, metadata: [String: Any]?) {
        ensureLogsDirectory()

        let proposedFileName = (metadata?["filename"] as? String) ?? temporaryURL.lastPathComponent
        let destinationURL = logsDirectoryURL.appendingPathComponent(proposedFileName)

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: temporaryURL, to: destinationURL)
            lastImportStatus = "Imported \(proposedFileName)"
        } catch {
            lastImportStatus = "Failed to import \(proposedFileName): \(error.localizedDescription)"
        }

        refreshImportedLogs()
    }

    func logContents(for logFile: ImportedWatchLogFile) -> String {
        (try? String(contentsOf: logFile.url, encoding: .utf8))
            ?? "Unable to read \(logFile.fileName)."
    }

    func refreshImportedLogs() {
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

        importedLogs = logURLs
            .filter { $0.pathExtension == "log" }
            .compactMap(makeLogFile(from:))
            .sorted { lhs, rhs in
                if lhs.modifiedAt == rhs.modifiedAt {
                    return lhs.fileName > rhs.fileName
                }
                return lhs.modifiedAt > rhs.modifiedAt
            }
    }

    private func ensureLogsDirectory() {
        try? fileManager.createDirectory(
            at: logsDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func makeLogFile(from url: URL) -> ImportedWatchLogFile? {
        guard let values = try? url.resourceValues(forKeys: [
            .creationDateKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey
        ]),
        values.isRegularFile == true else {
            return nil
        }

        return ImportedWatchLogFile(
            id: url.lastPathComponent,
            fileName: url.lastPathComponent,
            url: url,
            createdAt: values.creationDate ?? Date.distantPast,
            modifiedAt: values.contentModificationDate ?? values.creationDate ?? Date.distantPast,
            sizeInBytes: Int64(values.fileSize ?? 0)
        )
    }
}
