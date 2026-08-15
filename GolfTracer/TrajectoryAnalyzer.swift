import AVFoundation
import ImageIO
import UIKit

@MainActor
final class TrajectoryAnalyzer: ObservableObject {
    @Published var trajectories: [BallTrajectory] = []
    @Published var stillFrame: UIImage?
    @Published var sourceOrientation: CGImagePropertyOrientation = .up
    @Published var errorMessage: String?

    var bestTrajectory: BallTrajectory? { trajectories.first }

    func generateManualTrajectory(
        startPoint: CGPoint,
        apexPoint: CGPoint,
        endPoint: CGPoint,
        startTime: Double,
        endTime: Double,
        deceleration: Double,
        curveFactor: Double,
        orientation: CGImagePropertyOrientation
    ) -> BallTrajectory {
        ManualTrajectoryEngine.generate(
            startPoint: startPoint,
            apexPoint: apexPoint,
            endPoint: endPoint,
            startTime: startTime,
            endTime: endTime,
            apexTiming: deceleration,
            curve: curveFactor,
            orientation: orientation
        )
    }

    static func extractFrame(from url: URL, at time: CMTime) async throws -> UIImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let result = try await generator.image(at: time)
        return UIImage(cgImage: result.image)
    }
}
