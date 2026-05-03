import AVFoundation
import Foundation
import Vision

@MainActor
final class TrajectoryAnalyzer: ObservableObject {
    @Published var isAnalyzing = false
    @Published var trajectoryCount = 0
    @Published var errorMessage: String?

    func analyze(videoURL: URL) async {
        isAnalyzing = true
        trajectoryCount = 0
        errorMessage = nil

        do {
            let count = try await Self.detectTrajectories(in: videoURL)
            trajectoryCount = count
        } catch {
            errorMessage = error.localizedDescription
        }
        isAnalyzing = false
    }

    private static func detectTrajectories(in url: URL) async throws -> Int {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)

            // The handler fires repeatedly as Vision discovers/extends trajectories.
            // The final results represent everything detected during the run.
            var latestResults: [VNTrajectoryObservation] = []
            let lock = NSLock()

            let request = VNDetectTrajectoriesRequest(
                frameAnalysisSpacing: .zero,
                trajectoryLength: 5
            ) { request, _ in
                guard let trajectories = request.results as? [VNTrajectoryObservation] else { return }
                lock.lock()
                latestResults = trajectories
                lock.unlock()
            }

            let processor = VNVideoProcessor(url: url)
            try processor.addRequest(request, processingOptions: VNVideoProcessor.RequestProcessingOptions())
            try processor.analyze(CMTimeRange(start: .zero, duration: duration))

            return latestResults.count
        }.value
    }
}
