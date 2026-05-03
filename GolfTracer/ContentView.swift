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
            VStack(spacing: 20) {
                videoArea

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

                Button {
                    guard let url = videoURL else { return }
                    Task { await analyzer.analyze(videoURL: url) }
                } label: {
                    HStack {
                        if analyzer.isAnalyzing {
                            ProgressView().tint(.white)
                        }
                        Text(analyzer.isAnalyzing ? "Analyzing…" : "Analyze Trajectory")
                            .font(.headline)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(videoURL == nil ? Color.gray.opacity(0.2) : Color.green)
                    .foregroundStyle(videoURL == nil ? .secondary : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(videoURL == nil || analyzer.isAnalyzing)

                resultArea

                Spacer()
            }
            .padding()
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
                .frame(height: 360)
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

    @ViewBuilder
    private var resultArea: some View {
        if let error = analyzer.errorMessage {
            Text("Error: \(error)")
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        } else if !analyzer.isAnalyzing && analyzer.trajectoryCount > 0 {
            Text("Detected \(analyzer.trajectoryCount) trajector\(analyzer.trajectoryCount == 1 ? "y" : "ies")")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !analyzer.isAnalyzing && videoURL != nil && analyzer.trajectoryCount == 0 && analyzer.errorMessage == nil {
            EmptyView()
        }
    }

    private func placeholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.15))
            content()
        }
        .frame(height: 360)
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
