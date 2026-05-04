import AVKit
import PhotosUI
import SwiftUI
import Vision

struct ContentView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var isLoading = false
    @State private var showAllTrajectories = false
    @StateObject private var analyzer = TrajectoryAnalyzer()

    private var hasResult: Bool {
        analyzer.stillFrame != nil && !analyzer.observations.isEmpty
    }

    private var displayedTrajectories: [VNTrajectoryObservation] {
        if showAllTrajectories {
            return analyzer.observations
        }
        return analyzer.bestTrajectory.map { [$0] } ?? []
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                mainArea
                    .frame(maxHeight: .infinity)

                if let error = analyzer.errorMessage {
                    Text("Error: \(error)")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                pickButton
                analyzeButton
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
                        Button("Reset") { analyzer.observations = [] }
                    }
                }
            }
            .onChange(of: selectedItem) { _, newItem in
                Task { await loadVideo(from: newItem) }
            }
        }
    }

    @ViewBuilder
    private var mainArea: some View {
        if let still = analyzer.stillFrame, !analyzer.observations.isEmpty, let url = videoURL {
            VStack(alignment: .leading, spacing: 8) {
                let label = showAllTrajectories
                    ? "Showing all \(analyzer.trajectoryCount) trajectories"
                    : "Showing best trajectory (of \(analyzer.trajectoryCount))"
                Text(label)
                    .font(.headline)
                AnimatedTrajectoryView(
                    videoURL: url,
                    trajectories: displayedTrajectories,
                    orientation: analyzer.sourceOrientation,
                    aspectRatio: still.size.width / still.size.height
                )
                .id(url)
            }
        } else if let videoURL {
            VideoPlayer(player: AVPlayer(url: videoURL))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if isLoading {
            placeholder { ProgressView("Loading video…") }
        } else {
            placeholder {
                VStack(spacing: 8) {
                    Image(systemName: "video")
                        .font(.system(size: 40))
                    Text("No video selected")
                }
                .foregroundStyle(.secondary)
            }
        }
    }

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
            analyzeButtonLabel
        }
        .disabled(videoURL == nil || analyzer.isAnalyzing)
    }

    private var analyzeButtonLabel: some View {
        let enabled = videoURL != nil && !analyzer.isAnalyzing
        return HStack {
            if analyzer.isAnalyzing {
                ProgressView().tint(.white)
            }
            Text(analyzer.isAnalyzing ? "Analyzing…" : "Analyze Trajectory")
                .font(.headline)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(enabled ? Color.green : Color.gray.opacity(0.2))
        .foregroundStyle(enabled ? Color.white : Color.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func placeholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.15))
            content()
        }
    }

    private func runAnalysis() {
        guard let url = videoURL else { return }
        Task { await analyzer.analyze(videoURL: url) }
    }

    private func loadVideo(from item: PhotosPickerItem?) async {
        guard let item else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let movie = try await item.loadTransferable(type: Movie.self)
            videoURL = movie?.url
        } catch {
            print("Failed to load video:", error)
        }
    }
}

#Preview {
    ContentView()
}
