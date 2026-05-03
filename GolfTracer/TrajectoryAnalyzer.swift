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
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return []
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
                let handler = VNImageRequestHandler(
                    cmSampleBuffer: sampleBuffer,
                    orientation: orientation,
                    options: [:]
                )
                try? handler.perform([request])
            }

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

private func cgOrientation(from transform: CGAffineTransform) -> CGImagePropertyOrientation {
    // AVAssetTrack.preferredTransform encodes the rotation needed to display the video upright.
    // Vision wants a CGImagePropertyOrientation hint so it can return upright-space coordinates.
    if transform.a == 0 && transform.b == 1 && transform.c == -1 && transform.d == 0 {
        return .right   // 90° CW — typical portrait phone video
    } else if transform.a == 0 && transform.b == -1 && transform.c == 1 && transform.d == 0 {
        return .left    // 90° CCW
    } else if transform.a == -1 && transform.b == 0 && transform.c == 0 && transform.d == -1 {
        return .down    // 180°
    }
    return .up
}
