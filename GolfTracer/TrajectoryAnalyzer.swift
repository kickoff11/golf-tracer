import AVFoundation
import Foundation
import ImageIO
import UIKit
import Vision

@MainActor
final class TrajectoryAnalyzer: ObservableObject {
    @Published var isAnalyzing = false
    @Published var observations: [VNTrajectoryObservation] = []
    @Published var stillFrame: UIImage?
    @Published var sourceOrientation: CGImagePropertyOrientation = .up
    @Published var errorMessage: String?

    var trajectoryCount: Int { observations.count }

    var bestTrajectory: VNTrajectoryObservation? {
        observations.max { Self.score($0) < Self.score($1) }
    }

    private static func score(_ obs: VNTrajectoryObservation) -> Float {
        let points = obs.projectedPoints
        guard let first = points.first, let last = points.last else { return 0 }
        let dx = last.x - first.x
        let dy = last.y - first.y
        let displacement = sqrt(dx * dx + dy * dy)
        return obs.confidence * obs.confidence * Float(displacement)
    }

    func analyze(videoURL: URL) async {
        isAnalyzing = true
        observations = []
        stillFrame = nil
        errorMessage = nil

        do {
            let result = try await Self.detectTrajectories(in: videoURL)
            observations = result.observations
            sourceOrientation = result.orientation

            if let lastTime = result.observations.last?.timeRange.end {
                stillFrame = try? await Self.extractFrame(from: videoURL, at: lastTime)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isAnalyzing = false
    }

    private struct DetectionResult {
        let observations: [VNTrajectoryObservation]
        let orientation: CGImagePropertyOrientation
    }

    private static func detectTrajectories(in url: URL) async throws -> DetectionResult {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return DetectionResult(observations: [], orientation: .up)
            }
            let transform = try await track.load(.preferredTransform)
            let orientation = cgOrientation(from: transform)

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

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            )
            reader.add(output)
            reader.startReading()

            while let sampleBuffer = output.copyNextSampleBuffer() {
                let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, options: [:])
                try? handler.perform([request])
            }

            return DetectionResult(observations: latestResults, orientation: orientation)
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

private func cgOrientation(from transform: CGAffineTransform) -> CGImagePropertyOrientation {
    if transform.a == 0 && transform.b == 1 && transform.c == -1 && transform.d == 0 {
        return .right
    } else if transform.a == 0 && transform.b == -1 && transform.c == 1 && transform.d == 0 {
        return .left
    } else if transform.a == -1 && transform.b == 0 && transform.c == 0 && transform.d == -1 {
        return .down
    }
    return .up
}
