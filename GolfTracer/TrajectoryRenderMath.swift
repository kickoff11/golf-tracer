import CoreGraphics
import CoreMedia
import Foundation
import ImageIO

struct TrajectoryRenderFrame: Equatable {
    let pointRange: Range<Int>
    let globalAlpha: Double
}

enum TrajectoryRenderMath {
    static func frame(
        at seconds: Double,
        trajectory: BallTrajectory,
        curve: Double,
        trailLength: Double
    ) -> TrajectoryRenderFrame? {
        let start = CMTimeGetSeconds(trajectory.timeRange.start)
        let end = CMTimeGetSeconds(trajectory.timeRange.end)
        guard seconds >= start, !trajectory.points.isEmpty else { return nil }

        let linearProgress = seconds >= end
            ? 1.0
            : (seconds - start) / max(end - start, 0.0001)
        let exponent = 1.5 + max(0, curve)
        let progress = 1 - pow(1 - linearProgress, exponent)
        let total = trajectory.points.count
        let endIndex = max(1, min(total, Int(Double(total) * progress)))
        let retained = max(2, Int(Double(total) * min(max(trailLength, 0.05), 1)))
        let startIndex = max(0, endIndex - retained)
        let alpha = seconds > end ? max(0, 1 - (seconds - end) / 0.2) : 1
        guard alpha > 0 else { return nil }
        return TrajectoryRenderFrame(pointRange: startIndex..<endIndex, globalAlpha: alpha)
    }

    static func displayPoint(
        native point: CGPoint,
        orientation: CGImagePropertyOrientation,
        size: CGSize
    ) -> CGPoint {
        let upright: CGPoint
        switch orientation {
        case .right: upright = CGPoint(x: point.y, y: 1 - point.x)
        case .left: upright = CGPoint(x: 1 - point.y, y: point.x)
        case .down: upright = CGPoint(x: 1 - point.x, y: 1 - point.y)
        default: upright = point
        }
        return CGPoint(x: upright.x * size.width, y: (1 - upright.y) * size.height)
    }

    static func segmentAlpha(
        index: Int,
        count: Int,
        globalAlpha: Double,
        trailLength: Double
    ) -> Double {
        if trailLength >= 0.999 { return globalAlpha }
        let progress = Double(index) / Double(max(count - 1, 1))
        return progress * progress * globalAlpha
    }

    static func segmentWidth(index: Int, count: Int) -> Double {
        let progress = Double(index) / Double(max(count - 1, 1))
        return 2 + 5 * progress
    }
}
