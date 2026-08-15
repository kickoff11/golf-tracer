import CoreGraphics
import CoreMedia
import ImageIO
import Testing
@testable import GolfTracerCore

@Test func manualCurvePassesThroughSelectedPoints() {
    let start = CGPoint(x: 0.1, y: 0.2)
    let apex = CGPoint(x: 0.5, y: 0.8)
    let end = CGPoint(x: 0.9, y: 0.25)
    let trajectory = ManualTrajectoryEngine.generate(
        startPoint: start, apexPoint: apex, endPoint: end,
        startTime: 1, endTime: 3, apexTiming: 0.5, curve: 1,
        orientation: .up, sampleCount: 301
    )
    #expect(trajectory.points.first == start)
    #expect(trajectory.points[150].x.isApproximatelyEqual(to: apex.x))
    #expect(trajectory.points[150].y.isApproximatelyEqual(to: apex.y))
    #expect(trajectory.points.last == end)
}

@Test func orientationRoundTrips() {
    let point = CGPoint(x: 0.23, y: 0.71)
    for orientation in [CGImagePropertyOrientation.up, .right, .left, .down] {
        let visual = ManualTrajectoryEngine.visualPoint(from: point, orientation: orientation)
        let restored = ManualTrajectoryEngine.nativePoint(from: visual, orientation: orientation)
        #expect(restored.x.isApproximatelyEqual(to: point.x))
        #expect(restored.y.isApproximatelyEqual(to: point.y))
    }
}

@Test func previewAndExportUseDeterministicRenderFrame() {
    let trajectory = BallTrajectory(
        points: (0..<100).map { CGPoint(x: Double($0) / 99, y: 0.5) },
        timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
    )
    let first = TrajectoryRenderMath.frame(at: 1, trajectory: trajectory, curve: 1, trailLength: 0.25)
    let second = TrajectoryRenderMath.frame(at: 1, trajectory: trajectory, curve: 1, trailLength: 0.25)
    #expect(first == second)
    #expect(first?.pointRange.count == 25)
    #expect(TrajectoryRenderMath.frame(at: -0.01, trajectory: trajectory, curve: 1, trailLength: 1) == nil)
}

@Test func fixedShotFixtureKeepsCurveAndTimelineStable() throws {
    struct Fixture: Decodable {
        let start: StoredPoint
        let apex: StoredPoint
        let end: StoredPoint
        let startTime: Double
        let endTime: Double
        let apexTiming: Double
        let curve: Double
        let trailLength: Double
    }

    let fixtureURL = try #require(Bundle.module.url(
        forResource: "down-the-line-shot", withExtension: "json"
    ))
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
    let trajectory = ManualTrajectoryEngine.generate(
        startPoint: fixture.start.cgPoint,
        apexPoint: fixture.apex.cgPoint,
        endPoint: fixture.end.cgPoint,
        startTime: fixture.startTime,
        endTime: fixture.endTime,
        apexTiming: fixture.apexTiming,
        curve: fixture.curve,
        orientation: .up,
        sampleCount: 301
    )

    #expect(trajectory.points.count == 301)
    #expect(trajectory.points[150].x.isApproximatelyEqual(to: fixture.apex.cgPoint.x))
    #expect(trajectory.points[150].y.isApproximatelyEqual(to: fixture.apex.cgPoint.y))
    let frame = try #require(TrajectoryRenderMath.frame(
        at: 2,
        trajectory: trajectory,
        curve: fixture.curve,
        trailLength: fixture.trailLength
    ))
    #expect(frame.pointRange.count == 75)
    #expect(frame.globalAlpha == 1)
}

@Test func fullTrailIsSolidWhileShorterTrailsFade() {
    let solidStart = TrajectoryRenderMath.segmentAlpha(
        index: 1, count: 100, globalAlpha: 1, trailLength: 1
    )
    let solidEnd = TrajectoryRenderMath.segmentAlpha(
        index: 99, count: 100, globalAlpha: 1, trailLength: 1
    )
    let fadedStart = TrajectoryRenderMath.segmentAlpha(
        index: 1, count: 100, globalAlpha: 1, trailLength: 0.7
    )

    #expect(solidStart == 1)
    #expect(solidEnd == 1)
    #expect(fadedStart < solidStart)
}

private extension CGFloat {
    func isApproximatelyEqual(to other: CGFloat, tolerance: CGFloat = 0.000_001) -> Bool {
        abs(self - other) <= tolerance
    }
}
