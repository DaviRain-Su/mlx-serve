import SwiftUI

struct ModelDownloadView: View {
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(gemmaModelOptions8BitOnly) { option in
                ModelDownloadRow(option: option)
            }
        }
        .padding(.top, 4)
    }
}

struct ModelDownloadRow: View {
    let option: GemmaModelOption
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var appState: AppState

    private var state: DownloadManager.DownloadState? {
        downloads.downloads[option.repoId]
    }
    private var isReady: Bool {
        downloads.isReady(option.repoId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.displayName)
                        .font(.caption.weight(.medium))
                    Text(option.sizeEstimate)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()

                if isReady {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else if let state, state.status == .downloading {
                    // File progress bar
                    VStack(alignment: .trailing, spacing: 1) {
                        ProgressView(value: state.fileProgress)
                            .frame(width: 60)
                        Text("\(state.percentFormatted) \(state.speedFormatted)")
                            .font(.system(size: 8).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else if let state, state.status == .completed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else if let state, state.status == .failed {
                    Button(downloads.hasPartialDownload(option.repoId) ? "Resume" : "Retry") {
                        Task {
                            await downloads.download(repoId: option.repoId)
                            appState.refreshModels()
                        }
                    }
                    .font(.caption)
                    .controlSize(.mini)
                } else {
                    Button(downloads.hasPartialDownload(option.repoId) ? "Resume" : "Download") {
                        Task {
                            await downloads.download(repoId: option.repoId)
                            appState.refreshModels()
                        }
                    }
                    .font(.caption)
                    .controlSize(.mini)
                }
            }

            // Status text for active downloads
            if let state, state.status == .downloading, !state.statusText.isEmpty {
                Text("[\(state.fileIndex)/\(state.fileCount)] \(state.statusText)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let state, state.status == .failed, let error = state.error {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}
