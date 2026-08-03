import CoreGraphics
import CoreMedia
import Foundation

/// A finished, smooth golf-ball flight path ready to draw.
///
/// `points` are normalised to the range 0...1 with a bottom-left origin (x increases
/// to the right, y increases upward) — the same convention the detector produces, so
/// every view draws them with one consistent orientation calculation. These points are
/// sampled densely along a fitted curve, so the straight little segments between them
/// are far too short to look jagged: the eye reads one smooth arc.
struct BallTrajectory: Identifiable {
    let id = UUID()
    /// Densely-sampled smooth path, normalised (0...1), bottom-left origin.
    var points: [CGPoint]
    /// When the ball is in flight, used to reveal the arc progressively during playback.
    var timeRange: CMTimeRange
    /// 0...1 quality estimate. Used to pick the best path and to decide whether to
    /// discard an unreliable fit (likely noise) rather than draw it.
    var confidence: Float
}

/// Turns a cloud of noisy "the ball might be here at this moment" measurements into
/// one clean arc.
///
/// The maths in one paragraph: a golf ball in flight obeys gravity, so if you watch
/// only its sideways position it drifts at a near-constant rate (a straight line in
/// time), and its height rises then falls (a parabola in time). So we model the
/// horizontal position x and the vertical position y each as a quadratic function of
/// time. We use RANSAC (Random Sample Consensus — a standard technique that repeatedly
/// guesses a curve from a tiny random handful of points and keeps whichever guess the
/// most other points agree with) to ignore stray false detections, then refine the
/// winning curve against every point that agreed with it, and finally sample that
/// curve at many evenly-spaced moments to produce the smooth path.
enum TrajectoryFitter {

    /// One measurement: the ball *might* be at `point` (normalised, bottom-left) at `time` seconds.
    struct Sample {
        let point: CGPoint
        let time: Double
    }

    /// Fit a smooth arc to the supplied measurements.
    ///
    /// - Parameters:
    ///   - samples: candidate ball positions over time (may contain false positives).
    ///   - extrapolateFraction: how far past the last trusted detection to continue the
    ///     arc, as a fraction of the observed flight duration. Kept modest because
    ///     guessing the exact landing spot from only the early flight is unreliable;
    ///     the arc is also cut short the instant it would leave the frame.
    ///   - sampleCount: how many points to lay along the curve (more = smoother).
    ///   - inlierTolerance: how close (in normalised screen distance) a measurement must
    ///     sit to a guessed curve to count as agreeing with it.
    static func fit(
        samples: [Sample],
        extrapolateFraction: Double = 0.25,
        sampleCount: Int = 140,
        inlierTolerance: Double = 0.04
    ) -> BallTrajectory? {
        return fitMultiple(
            samples: samples,
            maxTrajectories: 1,
            extrapolateFraction: extrapolateFraction,
            sampleCount: sampleCount,
            inlierTolerance: inlierTolerance
        ).first
    }

    static func fitMultiple(
        samples: [Sample],
        maxTrajectories: Int = 3,
        extrapolateFraction: Double = 0.25,
        sampleCount: Int = 140,
        inlierTolerance: Double = 0.04
    ) -> [BallTrajectory] {
        let distinctTimes = Set(samples.map { $0.time }).count
        guard samples.count >= 3, distinctTimes >= 3 else { return [] }

        var remainingSamples = samples
        var results: [BallTrajectory] = []

        for _ in 0..<maxTrajectories {
            let activeDistinctTimes = Set(remainingSamples.map { $0.time }).count
            guard remainingSamples.count >= 3, activeDistinctTimes >= 3 else { break }

            let best = ransac(samples: remainingSamples, inlierTolerance: inlierTolerance)
            guard best.inliers.count >= 3 else { break }

            // Refit each axis against every agreeing measurement for an accurate final curve.
            let ts = best.inliers.map { $0.time }
            let xs = best.inliers.map { Double($0.point.x) }
            let ys = best.inliers.map { Double($0.point.y) }
            guard let fx = fitQuadratic(ts: ts, vs: xs),
                  let fy = fitQuadratic(ts: ts, vs: ys) else { break }

            let tStart = ts.min()!
            let tEnd   = ts.max()!
            let span   = max(tEnd - tStart, 0.0001)
            let tExtrapolatedEnd = tEnd + span * extrapolateFraction

            // Lay points evenly along the curve.
            var pts: [CGPoint] = []
            pts.reserveCapacity(sampleCount)
            let denom = Double(max(sampleCount - 1, 1))
            var lastKeptT = tStart
            for i in 0..<sampleCount {
                let t = tStart + (tExtrapolatedEnd - tStart) * (Double(i) / denom)
                let xv = fx.a * t * t + fx.b * t + fx.c
                let yv = fy.a * t * t + fy.b * t + fy.c
                let inFrame = xv >= -0.02 && xv <= 1.02 && yv >= -0.02 && yv <= 1.02
                if t > tEnd && !inFrame { break }
                pts.append(CGPoint(x: clamp01(xv), y: clamp01(yv)))
                lastKeptT = t
            }
            guard pts.count >= 2 else { continue }

            let timeRange = CMTimeRange(
                start: CMTime(seconds: tStart, preferredTimescale: 600),
                duration: CMTime(seconds: max(lastKeptT - tStart, 0.0001), preferredTimescale: 600)
            )

            // Calculate confidence relative to active flight window.
            let flightSamples = remainingSamples.filter { $0.time >= tStart && $0.time <= tEnd }
            let flightDistinctTimes = Set(flightSamples.map { $0.time }).count
            let ratio = Double(best.inliers.count) / Double(max(flightDistinctTimes, 1))
            let countFactor = min(1.0, Double(best.inliers.count) / 8.0)
            let tightness = max(0.4, 1 - (best.rms / inlierTolerance) * 0.6)
            let confidence = Float(max(0, min(1, ratio * countFactor * tightness)))

            results.append(BallTrajectory(points: pts, timeRange: timeRange, confidence: confidence))

            // Remove the inliers of this fit from the sample pool for the next iteration.
            let inlierKeys = Set(best.inliers.map { String(format: "%.4f_%.4f_%.4f", $0.time, $0.point.x, $0.point.y) })
            remainingSamples = remainingSamples.filter {
                let key = String(format: "%.4f_%.4f_%.4f", $0.time, $0.point.x, $0.point.y)
                return !inlierKeys.contains(key)
            }
        }

        return results
    }

    // MARK: – RANSAC

    private struct RansacResult { let inliers: [Sample]; let rms: Double }

    private static func ransac(samples: [Sample], inlierTolerance: Double) -> RansacResult {
        var rng = SystemRandomNumberGenerator()
        let iterations = min(300, max(60, samples.count * 12))
        var best = RansacResult(inliers: [], rms: .greatestFiniteMagnitude)

        for _ in 0..<iterations {
            // Pick three measurements at three distinct moments.
            guard let trio = pickThreeDistinctTimes(samples, using: &rng) else { continue }
            let ts = trio.map { $0.time }
            let xs = trio.map { Double($0.point.x) }
            let ys = trio.map { Double($0.point.y) }
            guard let fx = fitQuadratic(ts: ts, vs: xs),
                  let fy = fitQuadratic(ts: ts, vs: ys) else { continue }

            var inliers: [Sample] = []
            var sumSq = 0.0
            for s in samples {
                let px = fx.a * s.time * s.time + fx.b * s.time + fx.c
                let py = fy.a * s.time * s.time + fy.b * s.time + fy.c
                let dx = px - Double(s.point.x)
                let dy = py - Double(s.point.y)
                let d2 = dx * dx + dy * dy
                if d2 <= inlierTolerance * inlierTolerance {
                    inliers.append(s)
                    sumSq += d2
                }
            }
            let rms = inliers.isEmpty ? .greatestFiniteMagnitude : (sumSq / Double(inliers.count)).squareRoot()
            // Prefer more agreement; break ties by tighter fit.
            if inliers.count > best.inliers.count ||
               (inliers.count == best.inliers.count && rms < best.rms) {
                best = RansacResult(inliers: inliers, rms: rms)
            }
        }
        return best
    }

    private static func pickThreeDistinctTimes(
        _ samples: [Sample],
        using rng: inout SystemRandomNumberGenerator
    ) -> [Sample]? {
        guard samples.count >= 3 else { return nil }
        for _ in 0..<20 {
            let a = samples.randomElement(using: &rng)!
            let b = samples.randomElement(using: &rng)!
            let c = samples.randomElement(using: &rng)!
            if a.time != b.time && b.time != c.time && a.time != c.time { return [a, b, c] }
        }
        return nil
    }

    // MARK: – Curve fitting

    private struct Quadratic { let a: Double; let b: Double; let c: Double }

    /// Least-squares fit of value = a·t² + b·t + c. Falls back to a straight line when
    /// the data can't support a curve (e.g. only two distinct times).
    private static func fitQuadratic(ts: [Double], vs: [Double]) -> Quadratic? {
        guard ts.count == vs.count, ts.count >= 2 else { return nil }
        let distinct = Set(ts).count
        if distinct < 3 { return fitLinear(ts: ts, vs: vs) }

        var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0
        var b0 = 0.0, b1 = 0.0, b2 = 0.0
        for i in 0..<ts.count {
            let t = ts[i], v = vs[i]
            let t2 = t * t
            s0 += 1;       s1 += t;       s2 += t2
            s3 += t2 * t;  s4 += t2 * t2
            b0 += v;       b1 += v * t;   b2 += v * t2
        }
        // Normal equations: [s4 s3 s2; s3 s2 s1; s2 s1 s0] · [a b c] = [b2 b1 b0]
        let m = [[s4, s3, s2], [s3, s2, s1], [s2, s1, s0]]
        guard let sol = solve3x3(m, [b2, b1, b0]) else { return fitLinear(ts: ts, vs: vs) }
        return Quadratic(a: sol[0], b: sol[1], c: sol[2])
    }

    private static func fitLinear(ts: [Double], vs: [Double]) -> Quadratic? {
        let n = Double(ts.count)
        guard n >= 2 else { return nil }
        let sumT = ts.reduce(0, +)
        let sumV = vs.reduce(0, +)
        var sumTT = 0.0, sumTV = 0.0
        for i in 0..<ts.count { sumTT += ts[i] * ts[i]; sumTV += ts[i] * vs[i] }
        let denom = n * sumTT - sumT * sumT
        guard abs(denom) > 1e-12 else { return nil }
        let slope = (n * sumTV - sumT * sumV) / denom
        let intercept = (sumV - slope * sumT) / n
        return Quadratic(a: 0, b: slope, c: intercept)
    }

    private static func solve3x3(_ m: [[Double]], _ r: [Double]) -> [Double]? {
        let det =
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
            m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
            m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        guard abs(det) > 1e-12 else { return nil }

        func detReplacing(_ col: Int) -> Double {
            var c = m
            for row in 0..<3 { c[row][col] = r[row] }
            return
                c[0][0] * (c[1][1] * c[2][2] - c[1][2] * c[2][1]) -
                c[0][1] * (c[1][0] * c[2][2] - c[1][2] * c[2][0]) +
                c[0][2] * (c[1][0] * c[2][1] - c[1][1] * c[2][0])
        }
        return [detReplacing(0) / det, detReplacing(1) / det, detReplacing(2) / det]
    }

    private static func clamp01(_ v: Double) -> CGFloat { CGFloat(max(0, min(1, v))) }
}
