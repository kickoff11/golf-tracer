import CoreGraphics
import CoreMedia
import Foundation
import ImageIO

enum ManualTrajectoryEngine {
    static func generate(
        startPoint: CGPoint,
        apexPoint: CGPoint,
        endPoint: CGPoint,
        startTime: Double,
        endTime: Double,
        apexTiming: Double,
        curve: Double,
        orientation: CGImagePropertyOrientation,
        sampleCount: Int = 300
    ) -> BallTrajectory {
        let start = visualPoint(from: startPoint, orientation: orientation)
        let apex = visualPoint(from: apexPoint, orientation: orientation)
        let end = visualPoint(from: endPoint, orientation: orientation)
        let apexParameter = min(max(apexTiming, 0.1), 0.9)
        let oneMinusApex = 1 - apexParameter
        let denominator = 2 * oneMinusApex * apexParameter
        let control = CGPoint(
            x: (apex.x - oneMinusApex * oneMinusApex * start.x - apexParameter * apexParameter * end.x) / denominator,
            y: (apex.y - oneMinusApex * oneMinusApex * start.y - apexParameter * apexParameter * end.y) / denominator
        )

        let count = max(sampleCount, 3)
        var points: [CGPoint] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            let t = Double(index) / Double(count - 1)
            let inverse = 1 - t
            let startWeight = inverse * inverse
            let controlWeight = 2 * inverse * t
            let endWeight = t * t
            var visualX = startWeight * start.x + controlWeight * control.x + endWeight * end.x
            let visualY = startWeight * start.y + controlWeight * control.y + endWeight * end.y
            let local: Double
            if t <= apexParameter {
                let fraction = t / apexParameter
                local = fraction * (1 - fraction) * (1 - fraction) * 6.75
            } else {
                let fraction = (t - apexParameter) / (1 - apexParameter)
                local = fraction * fraction * (1 - fraction) * 6.75
            }
            visualX += local * (curve - 1) * 0.15
            let native = nativePoint(from: CGPoint(x: visualX, y: visualY), orientation: orientation)
            points.append(CGPoint(x: clamp(native.x), y: clamp(native.y)))
        }

        return BallTrajectory(
            points: points,
            timeRange: CMTimeRange(
                start: CMTime(seconds: max(0, startTime), preferredTimescale: 600),
                duration: CMTime(seconds: max(endTime - startTime, 0.1), preferredTimescale: 600)
            )
        )
    }

    static func visualPoint(from native: CGPoint, orientation: CGImagePropertyOrientation) -> CGPoint {
        switch orientation {
        case .right: return CGPoint(x: native.y, y: 1 - native.x)
        case .left: return CGPoint(x: 1 - native.y, y: native.x)
        case .down: return CGPoint(x: 1 - native.x, y: 1 - native.y)
        default: return native
        }
    }

    static func nativePoint(from visual: CGPoint, orientation: CGImagePropertyOrientation) -> CGPoint {
        switch orientation {
        case .right: return CGPoint(x: 1 - visual.y, y: visual.x)
        case .left: return CGPoint(x: visual.y, y: 1 - visual.x)
        case .down: return CGPoint(x: 1 - visual.x, y: 1 - visual.y)
        default: return visual
        }
    }

    private static func clamp(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }
}
