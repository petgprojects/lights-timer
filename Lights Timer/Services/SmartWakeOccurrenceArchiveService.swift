import Foundation

/// Retains watch diagnostics. Calibration belongs exclusively to the watch's
/// per-occurrence movement history; phone HealthKit data never tunes its rules.
@Observable
final class SmartWakeOccurrenceArchiveService {
    private struct StoredOccurrenceSummary: Codable {
        let summary: SmartWakeOccurrenceSummary
        let importedAt: Date
    }

    private let logStore: PhoneLogStore
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let summariesDirectoryURL: URL
    private let retainedSummaryCount = 30

    private(set) var statusMessage = "Waiting for watch occurrence summaries."
    private(set) var savedSummaryCount = 0
    private(set) var latestSummary: SmartWakeOccurrenceSummary?

    init(logStore: PhoneLogStore) {
        self.logStore = logStore
        let appSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        // Preserve the existing archive location and wrapper schema. The old
        // sibling profile.json is deliberately neither loaded nor applied.
        summariesDirectoryURL = appSupportURL
            .appendingPathComponent("SmartWakeCalibration", isDirectory: true)
            .appendingPathComponent("Occurrences", isDirectory: true)
        try? fileManager.createDirectory(at: summariesDirectoryURL, withIntermediateDirectories: true)
        refreshStatus()
        logStore.log("SmartWakeArchive", "Occurrence archive initialized; legacy phone calibration disabled")
    }

    func importOccurrenceSummary(_ summary: SmartWakeOccurrenceSummary) {
        let wrapped = StoredOccurrenceSummary(summary: summary, importedAt: Date())
        let fileURL = summariesDirectoryURL.appendingPathComponent(
            "occurrence-\(summary.id.uuidString).json"
        )
        do {
            try encoder.encode(wrapped).write(to: fileURL, options: .atomic)
            pruneStoredSummaries()
            refreshStatus()
            logStore.log(
                "SmartWakeArchive",
                "Imported occurrence \(summary.id.uuidString), algorithm=\(summary.algorithmIdentifier ?? "legacy"), schedule=\(summary.scheduleID.uuidString)"
            )
        } catch {
            statusMessage = "Failed to import Smart Wake occurrence summary."
            logStore.log(
                "SmartWakeArchive",
                "Failed to persist occurrence \(summary.id.uuidString): \(error.localizedDescription)",
                level: .error
            )
        }
    }

    private func summaryURLs() -> [URL] {
        ((try? fileManager.contentsOfDirectory(
            at: summariesDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("occurrence-") }
    }

    private func refreshStatus() {
        let summaries = summaryURLs().compactMap { url -> StoredOccurrenceSummary? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(StoredOccurrenceSummary.self, from: data)
        }
        savedSummaryCount = summaries.count
        latestSummary = summaries.max { $0.summary.createdAt < $1.summary.createdAt }?.summary
        statusMessage = summaries.isEmpty
            ? "Waiting for watch occurrence summaries."
            : "\(summaries.count) recent watch occurrence summaries saved."
    }

    private func pruneStoredSummaries() {
        let sortedURLs = summaryURLs().sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
        for url in sortedURLs.dropFirst(retainedSummaryCount) {
            try? fileManager.removeItem(at: url)
        }
    }
}
