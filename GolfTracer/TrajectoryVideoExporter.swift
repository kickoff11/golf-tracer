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
        orientation: CGImagePropertyOrientation
    ) async {
        status = .exporting
        do {
            let out = try await Self.render(videoURL: videoURL,
                                            trajectories: trajectories,
                                            orientation: orientation)
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
        orientation: CGImagePropertyOrientation
    ) async throws -> URL {
        let asset  = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw Err("No video track") }

        let naturalSize = try await track.load(.naturalSize)
        let transform   = try await track.load(.preferredTransform)

        // Display size after applying the preferred transform
        let displaySize: CGSize
        switch cgOrientation(from: transform) {
        case .right, .left: displaySize = CGSize(width: naturalSize.height, height: naturalSize.width)
        default:            displaySize = naturalSize
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GolfTracer_\(Int(Date().timeIntervalSince1970)).mp4")

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  Int(displaySize.width),
            AVVideoHeightKey: Int(displaySize.height)
        ]
        let writerInput   = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let adaptor       = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey  as String: Int(displaySize.width),
                kCVPixelBufferHeightKey as String: Int(displaySize.height)
            ]
        )
        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Read source frames
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)
        reader.startReading()

        let ciContext = CIContext()

        while let sample = readerOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard let srcBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

            // Apply preferred transform so the output is upright
            var ciImage = CIImage(cvPixelBuffer: srcBuffer).transformed(by: transform)
            // Re-centre after transform (transform may include translation)
            ciImage = ciImage.transformed(by:
                CGAffineTransform(translationX: -ciImage.extent.origin.x,
                                  y: -ciImage.extent.origin.y))

            // Draw trajectory overlay
            let overlay = Self.overlayImage(
                at: CMTimeGetSeconds(pts),
                trajectories: trajectories,
                orientation: orientation,
                size: displaySize
            )
            if let overlay {
                ciImage = overlay.composited(over: ciImage)
            }

            // Write to output buffer
            guard let pool = adaptor.pixelBufferPool else { break }
            var outBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
            guard let outBuffer else { break }
            ciContext.render(ciImage, to: outBuffer)

            while !writerInput.isReadyForMoreMediaData { await Task.yield() }
            adaptor.append(outBuffer, withPresentationTime: pts)
        }

        writerInput.markAsFinished()
        await writer.finishWriting()
        if let err = writer.error { throw err }
        return outputURL
    }

    // Build a transparent CIImage with the yellow trajectory lines for one frame.
    private static func overlayImage(
        at seconds: Double,
        trajectories: [BallTrajectory],
        orientation: CGImagePropertyOrientation,
        size: CGSize
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
                let progress = seconds >= end
                    ? 1.0 : (seconds - start) / max(end - start, 0.0001)
                let total   = traj.points.count
                guard total > 0 else { continue }
                let count   = max(1, min(total, Int(Double(total) * progress)))
                let pts     = traj.points.prefix(count).map { p in
                    uprightCGPoint(rawX: p.x, rawY: p.y, size: size, orientation: orientation)
                }
                guard pts.count > 1 else { continue }

                // Glow
                gc.setStrokeColor(UIColor.yellow.withAlphaComponent(0.4).cgColor)
                gc.setLineWidth(10)
                gc.move(to: pts[0])
                pts.dropFirst().forEach { gc.addLine(to: $0) }
                gc.strokePath()

                // Core line
                gc.setStrokeColor(UIColor.yellow.cgColor)
                gc.setLineWidth(3)
                gc.move(to: pts[0])
                pts.dropFirst().forEach { gc.addLine(to: $0) }
                gc.strokePath()

                // Leading dot
                if let lead = pts.last {
                    gc.setFillColor(UIColor.yellow.cgColor)
                    gc.fillEllipse(in: CGRect(x: lead.x-5, y: lead.y-5, width: 10, height: 10))
                }
            }
        }
        _ = scale  // suppress unused warning
        return CIImage(image: image)
    }

    // MARK: – Photos

    private static func saveToPhotos(url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
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
