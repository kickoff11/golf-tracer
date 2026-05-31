import AVKit
import PhotosUI
import SwiftUI

struct ContentView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var isLoading = false
    @State private var showAllTrajectories = false
    @StateObject private var analyzer  = TrajectoryAnalyzer()
    @StateObject private var exporter  = TrajectoryVideoExporter()

    private var hasResult: Bool {
        analyzer.stillFrame != nil && !analyzer.trajectories.isEmpty
    }

    private var displayedTrajectories: [BallTrajectory] {
        showAllTrajectories
            ? analyzer.trajectories
            : analyzer.bestTrajectory.map { [$0] } ?? []
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                mainArea
                    .frame(maxHeight: .infinity)

                if let error = analyzer.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                pickButton
                analyzeButton
                if hasResult { saveButton }
                exportStatus
            }
            .padding()
            .navigationTitle("Golf Tracer")
            .toolbar {
                if hasResult {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(showAllTrajectories ? "Show Best" : "Show All") {
                            showAllTrajectories.toggle()
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Reset") {
                            analyzer.trajectories = []
                            analyzer.stillFrame   = nil
                            analyzer.errorMessage = nil
                            showAllTrajectories   = false
                        }
                    }
                }
            }
            .onChange(of: selectedItem) { _, newItem in
                Task { await loadVideo(from: newItem) }
            }
        }
    }

    // MARK: – Main area

    @ViewBuilder
    private var mainArea: some View {
        if let still = analyzer.stillFrame, !analyzer.trajectories.isEmpty, let url = videoURL {
            VStack(alignment: .leading, spacing: 8) {
                let label = showAllTrajectories
                    ? "Showing all \(analyzer.trajectoryCount) trajectories"
                    : "Best trajectory (of \(analyzer.trajectoryCount))"
                Text(label).font(.headline)
                AnimatedTrajectoryView(
                    videoURL: url,
                    trajectories: displayedTrajectories,
                    orientation: analyzer.sourceOrientation,
                    aspectRatio: still.size.width / still.size.height
                )
                .id(url)
            }
        } else if let url = videoURL {
            VideoPlayer(player: AVPlayer(url: url))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if isLoading {
            placeholder { ProgressView("Loading video…") }
        } else {
            placeholder {
                VStack(spacing: 8) {
                    Image(systemName: "video")
                        .font(.system(size: 40))
                    Text("Pick a video to get started")
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: – Buttons

    private var pickButton: some View {
        PhotosPicker(
            selection: $selectedItem,
            matching: .videos,
            photoLibrary: .shared()
        ) {
            Label("Pick a video", systemImage: "video.badge.plus")
                .font(.headline)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var analyzeButton: some View {
        Button(action: runAnalysis) {
            HStack {
                if analyzer.isAnalyzing { ProgressView().tint(.white) }
                Text(analyzer.isAnalyzing ? "Analyzing…" : "Analyze Trajectory")
                    .font(.headline)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(videoURL == nil || analyzer.isAnalyzing
                        ? Color.gray.opacity(0.2) : Color.green)
            .foregroundStyle(videoURL == nil || analyzer.isAnalyzing
                             ? Color.secondary : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(videoURL == nil || analyzer.isAnalyzing)
    }

    private var saveButton: some View {
        Button(action: runExport) {
            HStack {
                if exporter.status == .exporting { ProgressView().tint(.white) }
                Text(exporter.status == .exporting ? "Saving…"
                     : exporter.status == .savedToPhotos ? "Saved ✓ — Save Again"
                     : "Save to Photos")
                    .font(.headline)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.purple)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(exporter.status == .exporting)
    }

    @ViewBuilder
    private var exportStatus: some View {
        switch exporter.status {
        case .savedToPhotos:
            Text("Saved to your photo library")
                .font(.callout).foregroundStyle(.green)
        case .failed(let msg):
            Text("Export failed: \(msg)")
                .font(.callout).foregroundStyle(.red)
                .multilineTextAlignment(.center).padding(.horizontal)
        default:
            EmptyView()
        }
    }

    // MARK: – Helpers

    private func placeholder<C: View>(@ViewBuilder content: () -> C) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.15))
            content()
        }
    }

    private func runAnalysis() {
        guard let url = videoURL else { return }
        Task { await analyzer.analyze(videoURL: url) }
    }

    private func runExport() {
        guard let url = videoURL, !analyzer.trajectories.isEmpty else { return }
        Task {
            await exporter.export(
                videoURL: url,
                trajectories: displayedTrajectories,
                orientation: analyzer.sourceOrientation
            )
        }
    }

    private func loadVideo(from item: PhotosPickerItem?) async {
        guard let item else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let movie = try await item.loadTransferable(type: Movie.self)
            videoURL          = movie?.url
            analyzer.trajectories = []
            analyzer.stillFrame   = nil
            analyzer.errorMessage = nil
            showAllTrajectories   = false
        } catch {
            print("Failed to load video:", error)
        }
    }
}

#Preview { ContentView() }
