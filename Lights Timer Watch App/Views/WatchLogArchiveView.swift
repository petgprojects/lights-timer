import SwiftUI

struct WatchLogArchiveView: View {
    @Binding var path: [WatchRootDestination]
    @Environment(SmartWakeLogStore.self) private var logStore
    @Environment(WatchSessionManager.self) private var sessionManager
    @State private var isConfirmingRuntimeLogClear = false

    var body: some View {
        List {
            runtimeLogSection
            latestSessionSection
            archiveSection
            transferSection
        }
        .navigationTitle("Watch Logs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                WatchTopMenu(path: $path, current: .logs)
            }
        }
        .onAppear {
            logStore.refreshAvailableLogsIfNeeded()
        }
        .confirmationDialog(
            "Clear Runtime Log?",
            isPresented: $isConfirmingRuntimeLogClear,
            titleVisibility: .visible
        ) {
            Button("Archive And Clear", role: .destructive) {
                logStore.clearRuntimeLog()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current runtime log will be saved with a timestamped name and a fresh smartwake-runtime.log will start immediately.")
        }
    }

    private var runtimeLogSection: some View {
        Section("Runtime Log") {
            if let runtimeLog = logStore.runtimeLogFile {
                logSummary(runtimeLog)

                NavigationLink("Open Runtime Log") {
                    WatchLogDetailView(logFile: runtimeLog)
                }

                ShareLink(item: runtimeLog, preview: SharePreview(runtimeLog.fileName)) {
                    Label("Share Runtime Log", systemImage: "square.and.arrow.up")
                }

                Button {
                    sessionManager.transferLogFile(runtimeLog.url)
                } label: {
                    Label("Send Runtime Log To iPhone", systemImage: "iphone")
                }

                Button(role: .destructive) {
                    isConfirmingRuntimeLogClear = true
                } label: {
                    Label("Clear Runtime Log", systemImage: "trash")
                }
            } else {
                Text("No watch logs yet")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private var latestSessionSection: some View {
        Section("Latest Session Log") {
            if let latestSessionLog = logStore.latestSessionLog {
                logSummary(latestSessionLog)

                NavigationLink("Open Latest Session Log") {
                    WatchLogDetailView(logFile: latestSessionLog)
                }

                ShareLink(item: latestSessionLog, preview: SharePreview(latestSessionLog.fileName)) {
                    Label("Share Latest Session Log", systemImage: "doc.text")
                }

                Button {
                    sessionManager.transferLogFile(latestSessionLog.url)
                } label: {
                    Label("Send Session Log To iPhone", systemImage: "iphone.gen3")
                }
            } else {
                Text("No session logs yet")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private var archiveSection: some View {
        Section("Saved Logs") {
            if logStore.availableLogs.isEmpty {
                Text("No watch logs yet")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(logStore.availableLogs) { logFile in
                    NavigationLink {
                        WatchLogDetailView(logFile: logFile)
                    } label: {
                        logSummary(logFile)
                    }
                }
            }
        }
    }

    private var transferSection: some View {
        Section("Transfer Status") {
            LabeledContent("iPhone Export") {
                Text(logStore.lastTransferStatus)
                    .font(.caption2)
            }
        }
    }

    private func logSummary(_ logFile: SmartWakeLogFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(logFile.displayName)
                .font(.caption)
            Text("\(formatDate(logFile.modifiedAt)) • \(logFile.sizeDescription)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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
