import SwiftUI

struct WatchLogArchiveView: View {
    @Environment(SmartWakeLogStore.self) private var logStore

    var body: some View {
        List {
            if let runtimeLog = logStore.runtimeLogFile {
                Section("Runtime Log") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(runtimeLog.displayName)
                            .font(.caption)
                        Text("\(formatDate(runtimeLog.modifiedAt)) • \(runtimeLog.sizeDescription)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink("Open Runtime Log") {
                        WatchLogDetailView(logFile: runtimeLog)
                    }
                }
            }

            Section("Saved Session Logs") {
                if logStore.availableLogs.isEmpty {
                    Text("No watch logs yet")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(logStore.availableLogs) { logFile in
                        NavigationLink {
                            WatchLogDetailView(logFile: logFile)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(logFile.displayName)
                                    .font(.caption)
                                Text("\(formatDate(logFile.modifiedAt)) • \(logFile.sizeDescription)")
                                    .font(.caption2)
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
    let logFile: SmartWakeLogFile

    var body: some View {
        ChunkedLogTextView(fileURL: logFile.url)
        .navigationTitle(logFile.displayName)
        .toolbar {
            ShareLink(item: logFile, preview: SharePreview(logFile.fileName)) {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }
}
