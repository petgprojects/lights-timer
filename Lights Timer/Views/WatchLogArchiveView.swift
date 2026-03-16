import SwiftUI

struct WatchLogArchiveView: View {
    @Environment(WatchLogArchiveService.self) private var watchLogArchive

    var body: some View {
        List {
            Section {
                Text(watchLogArchive.lastImportStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Imported Watch Logs") {
                if watchLogArchive.importedLogs.isEmpty {
                    Text("No watch logs have been imported yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(watchLogArchive.importedLogs) { logFile in
                        NavigationLink {
                            WatchLogDetailView(logFile: logFile)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(logFile.displayName)
                                Text("\(formatDate(logFile.modifiedAt)) • \(logFile.sizeDescription)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Watch Logs")
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct WatchLogDetailView: View {
    let logFile: ImportedWatchLogFile

    var body: some View {
        ChunkedLogTextView(fileURL: logFile.url)
        .navigationTitle(logFile.displayName)
        .toolbar {
            ShareLink(item: logFile.url) {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }
}
