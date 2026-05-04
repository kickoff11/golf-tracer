import CoreMedia
import Foundation

struct ManualTap: Equatable {
    let time: CMTime
    let normalizedPoint: CGPoint  // x, y in [0, 1] in upright display space
}

struct ManualTrajectory: Equatable {
    var taps: [ManualTap] = []

    var sortedTaps: [ManualTap] {
        taps.sorted { CMTimeCompare($0.time, $1.time) < 0 }
    }

    mutating func add(_ tap: ManualTap) {
        taps.append(tap)
    }

    mutating func removeLast() {
        guard !taps.isEmpty else { return }
        taps.removeLast()
    }

    mutating func clear() {
        taps.removeAll()
    }
}
