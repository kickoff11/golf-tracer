import AVFoundation
import Foundation
import ImageIO
import UIKit

@MainActor
final class TrajectoryAnalyzer: ObservableObject {
    @Published var isAnalyzing = false
    @Published var trajectories: [BallTrajectory] = []
    @Published var stillFrame: UIImage?
    @Published var sourceOrientation: CGImagePropertyOrientation = .up
    @Published var errorMessage: String?

    /// Below this, the fitted arc is judged unreliable — likely scattered noise rather
    /// than a real ball flight — and is discarded instead of drawn. A first estimate;
    /// tune against real footage.
    private static let minAcceptConfidence: Float = 0.30

    var trajectoryCount: Int { trajectories.count }

    var bestTrajectory: BallTrajectory? {
        trajectories.max { $0.confidence < $1.confidence }
    }

    func analyze(videoURL: URL) async {
        isAnalyzing  = true
        trajectories = []
        stillFrame   = nil
        errorMessage = nil

        do {
            // Locked-off-camera frame differencing finds white moving blobs; the fitter
            // keeps only the ones that line up into a single gravity-shaped arc.
            let detected = try await StaticCameraBallDetector.detect(in: videoURL)
            sourceOrientation = detected.orientation

            if let fit = TrajectoryFitter.fit(samples: detected.samples),
               fit.confidence >= Self.minAcceptConfidence {
                trajectories = [fit]
            }

            // Always extract a still frame so the aspect ratio is available even when no
            // ball is detected.
            let frameTime = trajectories.last?.timeRange.end
                         ?? detected.videoDuration.map { CMTimeMultiplyByFloat64($0, multiplier: 0.5) }
            if let t = frameTime {
                stillFrame = try? await Self.extractFrame(from: videoURL, at: t)
            }

            if trajectories.isEmpty {
                let fps = detected.nominalFPS.map { Int($0.rounded()) }
                if let fps, fps < 50 {
                    errorMessage = "No ball detected at \(fps) fps. Film at 60 fps or higher — " +
                        "in Settings, choose Camera > Record Video and pick 4K 60fps or 1080p 60fps."
                } else {
                    errorMessage = "No ball detected. Put the phone on a fixed tripod placed behind " +
                        "the golfer (down the line) and keep it perfectly still, so the moving ball " +
                        "stands out against the steady background."
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isAnalyzing = false
    }

    // MARK: – Frame extraction

    private static func extractFrame(from url: URL, at time: CMTime) async throws -> UIImage {
        let asset = AVURLAsset(url: url)
        let gen   = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform    = true
        gen.requestedTimeToleranceBefore      = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter       = CMTime(seconds: 0.5, preferredTimescale: 600)
        let result = try await gen.image(at: time)
        return UIImage(cgImage: result.image)
    }
}
