import AVFoundation
import PhotosUI
import SwiftUI

@MainActor
class TrajectoryVideoExporter: ObservableObject {
    enum ExportStatus: Equatable {
        case idle
        case exporting
        case completed(URL)
        case failed(String)
    }

    @Published var status: ExportStatus = .idle

    func export(
        videoURL: URL,
        trajectories: [BallTrajectory],
        orientation: CGImagePropertyOrientation,
        deceleration: Double,
        curveFactor: Double,
        tracerTheme: TracerTheme,
        tracerThickness: Double,
        tracerTailLength: Double
    ) async {
        self.status = .exporting
        do {
            let outputURL = try await Self.render(
                videoURL: videoURL,
                trajectories: trajectories,
                orientation: orientation,
                deceleration: deceleration,
                curveFactor: curveFactor,
                tracerTheme: tracerTheme,
                tracerThickness: tracerThickness,
                tracerTailLength: tracerTailLength
            )
            try await Self.saveToPhotos(url: outputURL)
            self.status = .completed(outputURL)
        } catch {
            self.status = .failed(error.localizedDescription)
        }
    }

    // MARK: – Rendering via GPU (CoreAnimation)

    private static func render(
        videoURL: URL,
        trajectories: [BallTrajectory],
        orientation: CGImagePropertyOrientation,
        deceleration: Double,
        curveFactor: Double,
        tracerTheme: TracerTheme,
        tracerThickness: Double,
        tracerTailLength: Double
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
        let durationCM = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationCM)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = displaySize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: durationCM)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(t, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // --- CoreAnimation Setup ---
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: displaySize)
        parentLayer.isGeometryFlipped = true // Match AVFoundation bottom-left video space

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(videoLayer)

        let overlayLayer = CALayer()
        overlayLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(overlayLayer)
        
        for traj in trajectories {
            let pts = traj.points
            guard pts.count > 1 else { continue }
            
            let startT = CMTimeGetSeconds(traj.timeRange.start)
            let endT = CMTimeGetSeconds(traj.timeRange.end)
            let flightDuration = max(endT - startT, 0.0001)
            
            let trajectoryLayer = CAShapeLayer()
            trajectoryLayer.frame = parentLayer.bounds
            trajectoryLayer.fillColor = UIColor.clear.cgColor
            
            // Use the most dominant color from the theme
            let themeColor = tracerTheme.colors.last ?? .white
            let uiColor = UIColor(themeColor)
            
            trajectoryLayer.strokeColor = uiColor.cgColor
            trajectoryLayer.lineWidth = tracerThickness
            trajectoryLayer.lineCap = .round
            trajectoryLayer.lineJoin = .round
            
            // Add a neon glow
            trajectoryLayer.shadowColor = uiColor.cgColor
            trajectoryLayer.shadowRadius = tracerThickness * 1.5
            trajectoryLayer.shadowOpacity = 0.8
            trajectoryLayer.shadowOffset = .zero
            
            let path = CGMutablePath()
            let firstPt = uprightCGPoint(rawX: pts[0].x, rawY: pts[0].y, size: displaySize, orientation: orientation)
            path.move(to: firstPt)
            
            for i in 1..<pts.count {
                let p = pts[i]
                let visualPt = uprightCGPoint(rawX: p.x, rawY: p.y, size: displaySize, orientation: orientation)
                path.addLine(to: visualPt)
            }
            trajectoryLayer.path = path
            
            // Animate strokeEnd to trace the path
            let anim = CABasicAnimation(keyPath: "strokeEnd")
            anim.fromValue = 0.0
            anim.toValue = 1.0
            anim.duration = flightDuration
            anim.beginTime = AVCoreAnimationBeginTimeAtZero + startT
            anim.fillMode = .both
            anim.isRemovedOnCompletion = false
            
            trajectoryLayer.add(anim, forKey: "strokeEnd")
            overlayLayer.addSublayer(trajectoryLayer)
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)

        let outputURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GolfTracer_\(UUID().uuidString).mov")
            
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

private struct Err: LocalizedError {
    let errorDescription: String?
    init(_ msg: String) { errorDescription = msg }
}
