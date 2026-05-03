import AVFoundation
import Foundation
import UIKit
import Vision

@MainActor
final class TrajectoryAnalyzer: ObservableObject {
    @Published var isAnalyzing = false
    @Published var observations: [VNTrajectoryObservation] = []
    @Published var stillFrame: UIImage?
    @Published var errorMessage: String?

    var trajectoryCount: Int { observations.count }

    func analyze(videoURL: URL) async {
        isAnalyzing = true
        observations = []
        stillFrame = nil
        errorMessage = nil

        do {
            let detected = try await Self.detectTrajectories(in: videoURL)
            observations = detected

            if let lastTime = detected.last?.timeRange.end {
                stillFrame = try? await Self.extractFrame(from: videoURL, at: lastTime)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isAnalyzing = false
    }

    private static func detectTrajectories(in url: URL) async throws -> [VNTrajectoryObservation] {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)

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

            return latestResults
        }.value
    }

    private static func extractFrame(from url: URL, at time: CMTime) async throws -> UIImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await generator.image(at: time)
        return UIImage(cgImage: result.image)
    }
}
