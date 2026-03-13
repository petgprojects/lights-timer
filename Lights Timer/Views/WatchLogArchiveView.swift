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
    @Environment(WatchLogArchiveService.self) private var watchLogArchive

    let logFile: ImportedWatchLogFile

    @State private var contents = ""

    var body: some View {
        ScrollView {
            Text(verbatim: contents)
                .font(.system(.caption2, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        }
        .padding(.horizontal)
        .navigationTitle(logFile.displayName)
        .toolbar {
            ShareLink(item: logFile.url) {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .task {
            contents = watchLogArchive.logContents(for: logFile)
        }
    }
}
