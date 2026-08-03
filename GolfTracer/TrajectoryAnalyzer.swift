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
    @Published var setupInfo: SetupDetector.SetupInfo?

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
            let detected = try await StaticCameraBallDetector.detect(in: videoURL)
            sourceOrientation = detected.orientation

            let fits = detected.trajectories
            let timeRange = detected.videoDuration.map { CMTimeRange(start: .zero, duration: $0) }
                            ?? CMTimeRange(start: .zero, duration: CMTime(seconds: 4.0, preferredTimescale: 600))

            trajectories = fits.compactMap { f -> BallTrajectory? in
                guard f.confidence >= Self.minAcceptConfidence else { return nil }
                return BallTrajectory(
                    points: f.points,
                    timeRange: timeRange,
                    confidence: f.confidence
                )
            }

            let frameTime = trajectories.last?.timeRange.end
                         ?? detected.videoDuration.map { CMTimeMultiplyByFloat64($0, multiplier: 0.5) }
            if let t = frameTime {
                stillFrame = try? await Self.extractFrame(from: videoURL, at: t)
            }

            if trajectories.isEmpty {
                let fps = detected.nominalFPS.map { Int($0.rounded()) }
                let bestConf = fits.max(by: { $0.confidence < $1.confidence })?.confidence ?? 0.0
                let debugText = "\n\n(Debug: Found \(detected.trajectories.count) candidate trajectories. Best fit confidence: \(String(format: "%.2f", bestConf)) vs required \(String(format: "%.2f", Self.minAcceptConfidence)))"
                
                if let fps, fps < 50 {
                    errorMessage = "No ball detected at \(fps) fps. Film at 60 fps or higher — " +
                        "in Settings, choose Camera > Record Video and pick 4K 60fps or 1080p 60fps." + debugText
                } else {
                    errorMessage = "No ball detected. Put the phone on a fixed tripod placed behind " +
                        "the golfer (down the line) and keep it perfectly still, so the moving ball " +
                        "stands out against the steady background." + debugText
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isAnalyzing = false
    }

    // MARK: - Manual Trajectory Generation

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
        // Convert native track points to visual normalized space
        let visStart = visualPoint(from: startPoint, orientation: orientation)
        let visApex  = visualPoint(from: apexPoint, orientation: orientation)
        let visEnd   = visualPoint(from: endPoint, orientation: orientation)

        var pts: [CGPoint] = []
        let sampleCount = 300
        let duration = max(endTime - startTime, 0.1)
        
        let u_a = min(max(deceleration, 0.05), 0.95)
        let alpha = max(curveFactor, 0.01)

        let X0 = visStart.x; let Y0 = visStart.y
        let Xa = visApex.x;  let Ya = visApex.y
        let X2 = visEnd.x;   let Y2 = visEnd.y
        
        let dy2 = Y2 - Y0
        let dya = Ya - Y0
        
        // Geometrically solve for the Bezier parameter tPeak where the vertical velocity is exactly zero
        var tPeak: Double = 0.5
        if abs(dy2) < 0.0001 {
            tPeak = 0.5
        } else {
            let A = dy2
            let B = -2.0 * dya
            let C = dya
            let discriminant = B * B - 4.0 * A * C
            
            if discriminant >= 0 {
                let sqrtD = sqrt(discriminant)
                let r1 = (-B + sqrtD) / (2.0 * A)
                let r2 = (-B - sqrtD) / (2.0 * A)
                
                if r1 > 0 && r1 < 1 { tPeak = r1 }
                else if r2 > 0 && r2 < 1 { tPeak = r2 }
            }
        }
        
        // Protect tPeak from edge cases
        tPeak = min(max(tPeak, 0.05), 0.95)
        
        // Solve for True 3D Perspective Control Points (w = w_shape for adjustable depth distortion)
        let coeffP0 = (1.0 - tPeak) * (1.0 - tPeak)
        let coeffP2 = tPeak * tPeak
        let coeffP1 = 2.0 * (1.0 - tPeak) * tPeak
        
        let Cy = (Ya - coeffP0 * Y0 - coeffP2 * Y2) / coeffP1
        let Cx = (Xa - coeffP0 * X0 - coeffP2 * X2) / coeffP1
        
        // Unified Time Warping (Piecewise Quadratic) - Guarantees slowest speed at apex, fast launch, and fast landing
        let safe_ua = u_a
        
        // Calculate base speeds required to hit the apex
        let speedL = tPeak / safe_ua
        let speedR = (1.0 - tPeak) / (1.0 - safe_ua)
        
        // Set the apex speed to be significantly slower than both (creates hang time)
        let vApex = 0.3 * min(speedL, speedR)
        
        // Calculate smoothness weights for both sides to guarantee C1 continuity
        let kL = vApex / speedL
        let kR = vApex / speedR
        
        for i in 0..<sampleCount {
            let u = Double(i) / Double(sampleCount - 1)
            
            let t: Double
            if u <= 0.0 { t = 0.0 }
            else if u >= 1.0 { t = 1.0 }
            else if u <= safe_ua {
                let v = u / safe_ua
                let f_v = (2.0 - kL) * v - (1.0 - kL) * v * v
                t = tPeak * f_v
            } else {
                let v = (u - safe_ua) / (1.0 - safe_ua)
                let g_v = (1.0 - kR) * v * v + kR * v
                t = tPeak + (1.0 - tPeak) * g_v
            }
            
            let invT = 1.0 - t
            
            // Standard Quadratic Bezier Evaluation
            let term0 = invT * invT
            let term1 = 2.0 * invT * t
            let term2 = t * t
            
            var currentX = term0 * X0 + term1 * Cx + term2 * X2
            var currentY = term0 * Y0 + term1 * Cy + term2 * Y2
            
            // Geometric Shape Tweak (Bends the curve horizontally to fit slices/hooks)
            let horizontalOffset: Double
            if t < tPeak {
                let x = t / tPeak
                let bulge = x * (1.0 - x) * (1.0 - x) * 6.75
                horizontalOffset = bulge * (curveFactor - 1.0) * 0.15
            } else {
                let x = (t - tPeak) / (1.0 - tPeak)
                let bulge = x * x * (1.0 - x) * 6.75
                horizontalOffset = bulge * (curveFactor - 1.0) * 0.15
            }
            
            switch orientation {
            case .right:
                currentY += horizontalOffset
            case .left:
                currentY -= horizontalOffset
            default:
                currentX += horizontalOffset
            }
            let nativePt = nativePoint(from: CGPoint(x: currentX, y: currentY), orientation: orientation)
            pts.append(CGPoint(x: max(0, min(1, nativePt.x)), y: max(0, min(1, nativePt.y))))
        }
        
        let timeRange = CMTimeRange(
            start: CMTime(seconds: startTime, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        
        return BallTrajectory(
            points: pts,
            timeRange: timeRange,
            confidence: 1.0
        )
    }

    private func visualPoint(from nativePoint: CGPoint, orientation: CGImagePropertyOrientation) -> CGPoint {
        let uX: CGFloat
        let uY: CGFloat
        switch orientation {
        case .right:
            uX = nativePoint.y
            uY = 1 - nativePoint.x
        case .left:
            uX = 1 - nativePoint.y
            uY = nativePoint.x
        case .down:
            uX = 1 - nativePoint.x
            uY = 1 - nativePoint.y
        default:
            uX = nativePoint.x
            uY = nativePoint.y
        }
        return CGPoint(x: uX, y: uY)
    }

    private func nativePoint(from visualPoint: CGPoint, orientation: CGImagePropertyOrientation) -> CGPoint {
        let rawX: CGFloat
        let rawY: CGFloat
        switch orientation {
        case .right:
            rawX = 1 - visualPoint.y
            rawY = visualPoint.x
        case .left:
            rawX = visualPoint.y
            rawY = 1 - visualPoint.x
        case .down:
            rawX = 1 - visualPoint.x
            rawY = 1 - visualPoint.y
        default:
            rawX = visualPoint.x
            rawY = visualPoint.y
        }
        return CGPoint(x: rawX, y: rawY)
    }

    static func extractFrame(from url: URL, at time: CMTime) async throws -> UIImage {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let cgImage = try await generator.image(at: time).image
        return UIImage(cgImage: cgImage)
    }
}
