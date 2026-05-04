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

    struct FittedSample {
        let time: CMTime
        let point: CGPoint
    }

    /// Fit a ballistic curve through the taps and return densely-sampled points.
    /// x is fit as linear in time (constant horizontal velocity);
    /// y is fit as quadratic in time (gravity acceleration).
    func fittedDensePoints(samples: Int = 80) -> [FittedSample] {
        let sorted = sortedTaps
        guard sorted.count >= 3 else { return [] }

        let times = sorted.map { CMTimeGetSeconds($0.time) }
        let xs = sorted.map { Double($0.normalizedPoint.x) }
        let ys = sorted.map { Double($0.normalizedPoint.y) }

        let (xa, xb) = linearFit(times: times, values: xs)
        let (ya, yb, yc) = quadraticFit(times: times, values: ys)

        let startTime = times.first!
        let endTime = times.last!
        let span = endTime - startTime
        guard samples > 1, span > 0 else { return [] }

        let dt = span / Double(samples - 1)
        var result: [FittedSample] = []
        result.reserveCapacity(samples)
        for i in 0..<samples {
            let t = startTime + Double(i) * dt
            let x = xa * t + xb
            let y = ya * t * t + yb * t + yc
            let time = CMTime(seconds: t, preferredTimescale: 600)
            result.append(FittedSample(time: time, point: CGPoint(x: x, y: y)))
        }
        return result
    }
}

private func linearFit(times: [Double], values: [Double]) -> (Double, Double) {
    let n = Double(times.count)
    let sumX = times.reduce(0, +)
    let sumY = values.reduce(0, +)
    let sumXY = zip(times, values).map(*).reduce(0, +)
    let sumX2 = times.map { $0 * $0 }.reduce(0, +)
    let denom = n * sumX2 - sumX * sumX
    let a = (n * sumXY - sumX * sumY) / denom
    let b = (sumY - a * sumX) / n
    return (a, b)
}

private func quadraticFit(times: [Double], values: [Double]) -> (Double, Double, Double) {
    var st = 0.0, st2 = 0.0, st3 = 0.0, st4 = 0.0
    var sy = 0.0, sty = 0.0, st2y = 0.0
    for (t, y) in zip(times, values) {
        let t2 = t * t
        st += t
        st2 += t2
        st3 += t2 * t
        st4 += t2 * t2
        sy += y
        sty += t * y
        st2y += t2 * y
    }
    let n = Double(times.count)
    let m: [[Double]] = [
        [n, st, st2],
        [st, st2, st3],
        [st2, st3, st4]
    ]
    let v = [sy, sty, st2y]
    let inv = invert3x3(m)
    let c = inv[0][0] * v[0] + inv[0][1] * v[1] + inv[0][2] * v[2]
    let b = inv[1][0] * v[0] + inv[1][1] * v[1] + inv[1][2] * v[2]
    let a = inv[2][0] * v[0] + inv[2][1] * v[1] + inv[2][2] * v[2]
    return (a, b, c)
}

private func invert3x3(_ m: [[Double]]) -> [[Double]] {
    let a = m[0][0], b = m[0][1], c = m[0][2]
    let d = m[1][0], e = m[1][1], f = m[1][2]
    let g = m[2][0], h = m[2][1], i = m[2][2]
    let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    let invDet = 1.0 / det
    return [
        [(e * i - f * h) * invDet, -(b * i - c * h) * invDet, (b * f - c * e) * invDet],
        [-(d * i - f * g) * invDet, (a * i - c * g) * invDet, -(a * f - c * d) * invDet],
        [(d * h - e * g) * invDet, -(a * h - b * g) * invDet, (a * e - b * d) * invDet]
    ]
}
