import SwiftUI

struct PhoneLogArchiveView: View {
    @Environment(PhoneLogStore.self) private var phoneLogStore

    var body: some View {
        List {
            Section {
                Text(phoneLogStore.captureStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Runtime Log") {
                if let runtimeLog = phoneLogStore.runtimeLogFile {
                    NavigationLink {
                        PhoneLogDetailView(logFile: runtimeLog)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(runtimeLog.displayName)
                            Text("\(formatDate(runtimeLog.modifiedAt)) • \(runtimeLog.sizeDescription)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ShareLink(item: runtimeLog.url) {
                        Label("Share Runtime Log", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Text("No iPhone runtime log has been recorded yet.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Launch Logs") {
                if phoneLogStore.availableLaunchLogs.isEmpty {
                    Text("No iPhone launch logs have been recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(phoneLogStore.availableLaunchLogs) { logFile in
                        NavigationLink {
                            PhoneLogDetailView(logFile: logFile)
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
        .navigationTitle("Phone Logs")
        .onAppear {
            phoneLogStore.refreshAvailableLogs()
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct PhoneLogDetailView: View {
    let logFile: PhoneLogFile

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
