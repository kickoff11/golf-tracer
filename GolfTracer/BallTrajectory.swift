import CoreGraphics
import CoreMedia
import Foundation

/// A user-confirmed golf-ball flight path ready for preview and export.
/// Points use normalized native-video coordinates with a bottom-left origin.
struct BallTrajectory: Identifiable {
    let id = UUID()
    var points: [CGPoint]
    var timeRange: CMTimeRange
}
