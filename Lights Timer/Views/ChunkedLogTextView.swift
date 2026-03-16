import SwiftUI

struct ChunkedLogTextView: View {
    let fileURL: URL

    @State private var chunks: [LogTextChunk] = []
    @State private var loadError: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading Log")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                Text(loadError)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding()
            } else if chunks.isEmpty {
                Text("Log is empty.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(chunks) { chunk in
                            Text(verbatim: chunk.text)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                .padding(.horizontal)
            }
        }
        .task(id: fileURL) {
            await loadContents()
        }
    }

    @MainActor
    private func loadContents() async {
        isLoading = true
        loadError = nil

        let url = fileURL
        let result = await Task.detached(priority: .userInitiated) {
            LogTextChunkLoader.load(from: url, maxLinesPerChunk: 200)
        }.value

        isLoading = false
        switch result {
        case .success(let loadedChunks):
            chunks = loadedChunks
        case .failure(let error):
            chunks = []
            loadError = error.localizedDescription
        }
    }
}

private struct LogTextChunk: Identifiable, Hashable, Sendable {
    let id: Int
    let text: String
}

private enum LogTextChunkLoadError: LocalizedError, Sendable {
    case unreadableFile(fileName: String, description: String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let fileName, let description):
            return "Unable to read \(fileName): \(description)"
        }
    }
}

private enum LogTextChunkLoader {
    nonisolated static func load(
        from url: URL,
        maxLinesPerChunk: Int
    ) -> Result<[LogTextChunk], LogTextChunkLoadError> {
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            return .success(makeChunks(from: contents, maxLinesPerChunk: maxLinesPerChunk))
        } catch {
            return .failure(
                .unreadableFile(
                    fileName: url.lastPathComponent,
                    description: error.localizedDescription
                )
            )
        }
    }

    nonisolated private static func makeChunks(
        from contents: String,
        maxLinesPerChunk: Int
    ) -> [LogTextChunk] {
        guard !contents.isEmpty else { return [] }

        var chunks: [LogTextChunk] = []
        chunks.reserveCapacity(max(1, contents.count / 16_384))

        var bufferedLines: [Substring] = []
        bufferedLines.reserveCapacity(maxLinesPerChunk)
        var chunkIndex = 0

        for line in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            bufferedLines.append(line)

            if bufferedLines.count >= maxLinesPerChunk {
                chunks.append(LogTextChunk(id: chunkIndex, text: bufferedLines.joined(separator: "\n")))
                chunkIndex += 1
                bufferedLines.removeAll(keepingCapacity: true)
            }
        }

        if !bufferedLines.isEmpty {
            chunks.append(LogTextChunk(id: chunkIndex, text: bufferedLines.joined(separator: "\n")))
        }

        return chunks
    }
}
