import AVFoundation
import CoreImage
import CoreGraphics
import Foundation
import ImageIO
import Photos
import UIKit

@MainActor
final class TrajectoryVideoExporter: ObservableObject {
    enum Status: Equatable {
        case idle, exporting, savedToPhotos
        case failed(String)
    }
    @Published var status: Status = .idle

    func export(
        videoURL: URL,
        trajectories: [BallTrajectory],
        orientation: CGImagePropertyOrientation,
        deceleration: Double,
        curveFactor: Double
    ) async {
        status = .exporting
        do {
            let out = try await Self.render(
                videoURL: videoURL,
                trajectories: trajectories,
                orientation: orientation,
                deceleration: deceleration,
                curveFactor: curveFactor
            )
            try await Self.saveToPhotos(url: out)
            status = .savedToPhotos
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: – Rendering

    private static func render(
        videoURL: URL,
        trajectories: [BallTrajectory],
        orientation: CGImagePropertyOrientation,
        deceleration: Double,
        curveFactor: Double
    ) async throws -> URL {
        let asset  = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw Err("No video track") }

        let size = try await track.load(.naturalSize)
        let t = try await track.load(.preferredTransform)
        let displaySize = CGSize(
            width: abs(size.width * t.a + size.height * t.c),
            height: abs(size.width * t.b + size.height * t.d)
        )
        
        let videoComposition = AVVideoComposition(asset: asset) { request in
            let seconds = CMTimeGetSeconds(request.compositionTime)
            
            // Generate the overlay image
            let overlay = Self.overlayImage(
                at: seconds,
                trajectories: trajectories,
                orientation: orientation,
                size: displaySize,
                deceleration: deceleration,
                curveFactor: curveFactor
            )
            
            // AVVideoComposition(asset:applyingCIFiltersWithHandler:) automatically applies the track's preferred transform
            // so request.sourceImage is already properly rotated/oriented!
            var finalImage = request.sourceImage
            if let overlay {
                // We composite the overlay over the source image
                finalImage = overlay.composited(over: request.sourceImage)
            }
            request.finish(with: finalImage, context: nil)
        }
        
        let outputURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GolfTracer_\(UUID().uuidString).mov")
            
        // Using HEVC 1080p for hardware-accelerated high-quality encoding
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVC1920x1080) else {
            throw Err("Cannot create export session")
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.videoComposition = videoComposition
        
        await exportSession.export()
        
        if exportSession.status == .failed {
            throw exportSession.error ?? Err("Export failed")
        }
        
        return outputURL
    }

    // Build a transparent CIImage with the yellow trajectory lines for one frame.
    private static func overlayImage(
        at seconds: Double,
        trajectories: [BallTrajectory],
        orientation: CGImagePropertyOrientation,
        size: CGSize,
        deceleration: Double,
        curveFactor: Double
    ) -> CIImage? {
        let scale = UIScreen.main.scale
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1          // 1:1 pixel, not point
        fmt.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: fmt)

        let image = renderer.image { ctx in
            let gc = ctx.cgContext
            gc.setLineCap(.round)
            gc.setLineJoin(.round)

            for traj in trajectories {
                let start = CMTimeGetSeconds(traj.timeRange.start)
                let end   = CMTimeGetSeconds(traj.timeRange.end)
                guard seconds >= start else { continue }
                let linearProgress = seconds >= end
                    ? 1.0 : (seconds - start) / max(end - start, 0.0001)
                
                let globalAlpha: Double = seconds > end
                    ? max(0.0, 1.0 - (seconds - end) / 0.2)
                    : 1.0
                    
                guard globalAlpha > 0 else { continue }
                
                // Realistic aerodynamic deceleration modulated by the user's slider
                let exponent = 1.5 + max(0.0, curveFactor)
                let progress = 1.0 - pow(1.0 - linearProgress, exponent)
                
                let total   = traj.points.count
                guard total > 0 else { continue }
                let count   = max(1, min(total, Int(Double(total) * progress)))
                let pts     = traj.points.prefix(count).map { p in
                    uprightCGPoint(rawX: p.x, rawY: p.y, size: size, orientation: orientation)
                }
                guard pts.count > 1 else { continue }

                // Draw as a fading comet trail!
                let pointCount = pts.count
                for i in 1..<pointCount {
                    let p1 = pts[i - 1]
                    let p2 = pts[i]
                    
                    let segmentProgress = Double(i) / Double(pointCount)
                    let alpha = segmentProgress * segmentProgress * globalAlpha
                    
                    if alpha < 0.02 { continue } // CULL invisible tail segments for massive speedup!
                    
                    let thickness = 2.0 + (5.0 * segmentProgress)
                    let glowColor = UIColor.red.withAlphaComponent(CGFloat(alpha * 0.4)).cgColor
                    let coreColor = UIColor.red.withAlphaComponent(CGFloat(alpha)).cgColor
                    
                    // Subtle glow
                    gc.setStrokeColor(glowColor)
                    gc.setLineWidth(thickness * 2.5)
                    gc.move(to: p1)
                    gc.addLine(to: p2)
                    gc.strokePath()
                    
                    // Core line
                    gc.setStrokeColor(coreColor)
                    gc.setLineWidth(thickness)
                    gc.move(to: p1)
                    gc.addLine(to: p2)
                    gc.strokePath()
                }

                // Tiny bright tip
                if let lead = pts.last {
                    gc.setFillColor(UIColor.red.withAlphaComponent(CGFloat(globalAlpha)).cgColor)
                    gc.fillEllipse(in: CGRect(x: lead.x - 2.5, y: lead.y - 2.5, width: 5, height: 5))
                }
            }
        }
        _ = scale  // suppress unused warning
        return CIImage(image: image)
    }

    // MARK: – Photos

    private static func saveToPhotos(url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw Err("Photo library access denied. Please enable in Settings.")
        }
        
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: nil)
                request.creationDate = Date()
            }) { ok, err in
                if ok { cont.resume() } else { cont.resume(throwing: err ?? Err("Photos save failed")) }
            }
        }
    }
}

// MARK: – Helpers

private func uprightCGPoint(
    rawX: CGFloat, rawY: CGFloat,
    size: CGSize,
    orientation: CGImagePropertyOrientation
) -> CGPoint {
    let (uX, uY): (CGFloat, CGFloat)
    switch orientation {
    case .right:  uX = rawY;       uY = 1 - rawX
    case .left:   uX = 1 - rawY;   uY = rawX
    case .down:   uX = 1 - rawX;   uY = 1 - rawY
    default:      uX = rawX;       uY = rawY
    }
    return CGPoint(x: uX * size.width, y: (1 - uY) * size.height)
}

private func cgOrientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
    if t.a == 0 && t.b ==  1 && t.c == -1 && t.d == 0 { return .right }
    if t.a == 0 && t.b == -1 && t.c ==  1 && t.d == 0 { return .left  }
    if t.a == -1 && t.b == 0 && t.c ==  0 && t.d == -1 { return .down }
    return .up
}

private struct Err: LocalizedError {
    let errorDescription: String?
    init(_ msg: String) { errorDescription = msg }
}
