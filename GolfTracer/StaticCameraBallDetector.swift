import AVFoundation
import CoreGraphics
import CoreMedia
import ImageIO
import Foundation
import Vision

/// Finds candidate golf-ball trajectories in footage shot from a locked-off tripod using Apple's Vision framework.
///
/// This dumps the custom frame-differencing model in favor of Apple's built-in, hardware-accelerated
/// `VNDetectTrajectoriesRequest` which is designed specifically to detect projectiles (like golf balls)
/// moving along a parabolic path and automatically filter out human limbs, gloves, or background clutter.
enum StaticCameraBallDetector {

    struct Result {
        let trajectories: [BallTrajectory]
        let orientation: CGImagePropertyOrientation
        let nominalFPS: Float?
        let videoDuration: CMTime?
    }

    static func detect(in url: URL) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return Result(trajectories: [], orientation: .up, nominalFPS: nil, videoDuration: nil)
            }

            let transform = try await track.load(.preferredTransform)
            let fps        = try await track.load(.nominalFrameRate)
            let duration   = try await asset.load(.duration)
            let orientation = cgOrientation(from: transform)

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            )
            output.alwaysCopiesSampleData = false
            reader.add(output)
            reader.startReading()

            var trajectoriesByUUID: [UUID: BallTrajectory] = [:]
            
            // Create a stateful trajectory detection request.
            // trajectoryLength = 5 frames (minimum points to form a trajectory).
            let request = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero, trajectoryLength: 5)
            let sequenceHandler = VNSequenceRequestHandler()

            while let sampleBuffer = output.copyNextSampleBuffer() {
                try sequenceHandler.perform([request], on: sampleBuffer, orientation: orientation)
                
                if let results = request.results {
                    for observation in results {
                        // Map the Vision observation's projectedPoints directly to BallTrajectory points.
                        // Both systems use the normalized bottom-left origin coordinate system.
                        let pts = observation.projectedPoints.map { point in
                            CGPoint(x: point.location.x, y: point.location.y)
                        }
                        
                        if pts.count >= 2 {
                            let trajectory = BallTrajectory(
                                points: pts,
                                timeRange: observation.timeRange,
                                confidence: observation.confidence
                            )
                            trajectoriesByUUID[observation.uuid] = trajectory
                        }
                    }
                }
            }

            return Result(
                trajectories: Array(trajectoriesByUUID.values),
                orientation: orientation,
                nominalFPS: fps,
                videoDuration: duration
            )
        }.value
    }
}

private func cgOrientation(from transform: CGAffineTransform) -> CGImagePropertyOrientation {
    if transform.a == 0 && transform.b ==  1 && transform.c == -1 && transform.d == 0 { return .right }
    if transform.a == 0 && transform.b == -1 && transform.c ==  1 && transform.d == 0 { return .left  }
    if transform.a == -1 && transform.b == 0 && transform.c ==  0 && transform.d == -1 { return .down }
    return .up
}
