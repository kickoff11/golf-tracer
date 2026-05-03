import AVKit
import PhotosUI
import SwiftUI

struct ContentView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var isLoading = false
    @StateObject private var analyzer = TrajectoryAnalyzer()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    videoArea
                    pickButton
                    analyzeButton
                    resultArea
                }
                .padding()
            }
            .navigationTitle("Golf Tracer")
            .onChange(of: selectedItem) { _, newItem in
                Task { await loadVideo(from: newItem) }
            }
        }
    }

    @ViewBuilder
    private var videoArea: some View {
        if let videoURL {
            VideoPlayer(player: AVPlayer(url: videoURL))
                .frame(height: 300)
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

    @ViewBuilder
    private var resultArea: some View {
        if let error = analyzer.errorMessage {
            Text("Error: \(error)")
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        } else if let still = analyzer.stillFrame, !analyzer.observations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                let plural = analyzer.trajectoryCount == 1 ? "y" : "ies"
                Text("Detected \(analyzer.trajectoryCount) trajector\(plural)")
                    .font(.headline)
                TrajectoryOverlayView(
                    stillFrame: still,
                    trajectories: analyzer.observations
                )
            }
        }
    }

    private func placeholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.15))
            content()
        }
        .frame(height: 300)
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
