import AVFoundation
import CoreImage
import Foundation
import Photos
import UIKit

@MainActor
final class TrajectoryVideoExporter: ObservableObject {
    enum Status: Equatable {
        case idle
        case exporting
        case savedToPhotos
        case failed(String)
    }

    @Published var status: Status = .idle

    func export(videoURL: URL, trajectory: ManualTrajectory) async {
        status = .exporting
        do {
            print("[Exporter] starting render…")
            let outputURL = try await renderAnnotated(videoURL: videoURL, trajectory: trajectory)
            print("[Exporter] render done at \(outputURL.path), saving to Photos…")
            try await saveToPhotos(url: outputURL)
            print("[Exporter] saved.")
            status = .savedToPhotos
        } catch {
            print("[Exporter] failed:", error)
            status = .failed(error.localizedDescription)
        }
    }

    // Render the trace by reading frames, drawing a CIImage overlay, writing a new file.
    // This avoids AVVideoCompositionCoreAnimationTool, which is unreliable in Simulator.
    private func renderAnnotated(videoURL: URL, trajectory: ManualTrajectory) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)

        // The displayed (upright) size after applying preferredTransform.
        let renderSize = uprightSize(natural: naturalSize, transform: preferredTransform)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(renderSize.width),
                AVVideoHeightKey: Int(renderSize.height)
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(renderSize.width),
                kCVPixelBufferHeightKey as String: Int(renderSize.height)
            ]
        )
        writer.add(writerInput)

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        guard reader.startReading() else { throw ExportError.readerFailed }
        guard writer.startWriting() else { throw ExportError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext(options: nil)
        let fittedSamples = trajectory.fittedDensePoints()
        let sortedTaps = trajectory.sortedTaps
        let trailStart = sortedTaps.first.map { CMTimeGetSeconds($0.time) } ?? 0
        let trailEnd = sortedTaps.last.map { CMTimeGetSeconds($0.time) } ?? CMTimeGetSeconds(duration)

        let frameDuration = CMTime(value: 1, timescale: max(Int32(nominalFrameRate.rounded()), 30))
        _ = frameDuration  // silence unused warning if frame-rate logic changes

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "GolfTracer.Export")
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: writer.error ?? ExportError.writerFailed)
                            }
                        }
                        return
                    }

                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let seconds = CMTimeGetSeconds(presentationTime)

                    let composed = self.compose(
                        pixelBuffer: pixelBuffer,
                        time: seconds,
                        trailStart: trailStart,
                        trailEnd: trailEnd,
                        samples: fittedSamples,
                        upright: renderSize,
                        transform: preferredTransform,
                        natural: naturalSize,
                        ciContext: ciContext
                    )

                    if let composed {
                        if !pixelAdaptor.append(composed, withPresentationTime: presentationTime) {
                            print("[Exporter] append failed at \(seconds)")
                        }
                    }
                }
            }
        }
        return outputURL
    }

    private func compose(
        pixelBuffer: CVPixelBuffer,
        time: Double,
        trailStart: Double,
        trailEnd: Double,
        samples: [ManualTrajectory.FittedSample],
        upright: CGSize,
        transform: CGAffineTransform,
        natural: CGSize,
        ciContext: CIContext
    ) -> CVPixelBuffer? {
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Rotate source to upright, then translate so the upright frame sits at (0,0).
        var t = transform
        let postRotateBounds = CGRect(origin: .zero, size: natural).applying(transform)
        t.tx -= postRotateBounds.origin.x
        t.ty -= postRotateBounds.origin.y
        let uprightImage = sourceImage.transformed(by: t)

        // Force the upright image to start exactly at (0,0) with exactly `upright` size.
        // (Defensive: small rounding errors can leave extent slightly off, which then
        // expands the union extent and shrinks the video relative to the overlay.)
        let cropRect = CGRect(origin: .zero, size: upright)
        let cropped = uprightImage.cropped(to: cropRect)

        let overlay = renderTraceOverlay(
            size: upright,
            time: time,
            trailStart: trailStart,
            trailEnd: trailEnd,
            samples: samples
        )

        let composed: CIImage
        if let overlay, let cgOverlay = overlay.cgImage {
            let overlayCI = CIImage(cgImage: cgOverlay)
            // CIImage origin is bottom-left; UIGraphics overlay was drawn top-left.
            // Flip overlay vertically so its top-left maps to the upright top-left.
            let flipped = overlayCI
                .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
                .transformed(by: CGAffineTransform(translationX: 0, y: upright.height))
            composed = flipped.composited(over: cropped)
        } else {
            composed = cropped
        }

        var output: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(upright.width),
            Int(upright.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &output
        )
        guard let out = output else { return nil }
        ciContext.render(composed, to: out, bounds: cropRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        return out
    }

    private func renderTraceOverlay(
        size: CGSize,
        time: Double,
        trailStart: Double,
        trailEnd: Double,
        samples: [ManualTrajectory.FittedSample]
    ) -> UIImage? {
        guard size.width > 0, size.height > 0, samples.count > 1 else { return nil }
        guard time >= trailStart else { return nil }

        let progress = time >= trailEnd ? 1.0 : (time - trailStart) / max(trailEnd - trailStart, 0.001)
        let visibleCount = max(2, Int(Double(samples.count) * progress))
        let visible = Array(samples.prefix(visibleCount))

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            ctx.cgContext.setLineCap(.round)
            ctx.cgContext.setLineJoin(.round)

            let lineWidth = max(4, size.width * 0.005)
            let glowWidth = lineWidth * 3

            let path = UIBezierPath()
            let start = CGPoint(
                x: visible[0].point.x * size.width,
                y: visible[0].point.y * size.height
            )
            path.move(to: start)
            for sample in visible.dropFirst() {
                path.addLine(to: CGPoint(x: sample.point.x * size.width, y: sample.point.y * size.height))
            }

            UIColor.systemYellow.withAlphaComponent(0.45).setStroke()
            path.lineWidth = glowWidth
            path.stroke()

            UIColor.systemYellow.setStroke()
            path.lineWidth = lineWidth
            path.stroke()

            // Lead dot
            if let last = visible.last {
                let leadPoint = CGPoint(x: last.point.x * size.width, y: last.point.y * size.height)
                let radius = lineWidth * 1.6
                let dotRect = CGRect(
                    x: leadPoint.x - radius,
                    y: leadPoint.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                UIColor.systemYellow.setFill()
                UIBezierPath(ovalIn: dotRect).fill()
            }
        }
    }

    private func uprightSize(natural: CGSize, transform: CGAffineTransform) -> CGSize {
        let isRotated = abs(transform.b) > 0.5 && abs(transform.c) > 0.5
        return isRotated
            ? CGSize(width: natural.height, height: natural.width)
            : natural
    }

    // Compose: translate to positive coords after applying preferredTransform.
    private func uprightTransform(natural: CGSize, transform: CGAffineTransform) -> CGAffineTransform {
        var t = transform
        let bounds = CGRect(origin: .zero, size: natural).applying(t)
        t.tx -= bounds.origin.x
        t.ty -= bounds.origin.y
        return t
    }

    private func saveToPhotos(url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportError.photosAccessDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        }
    }

    enum ExportError: LocalizedError {
        case noVideoTrack
        case readerFailed
        case writerFailed
        case photosAccessDenied

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "Video has no video track"
            case .readerFailed: return "Could not read video"
            case .writerFailed: return "Could not write output video"
            case .photosAccessDenied: return "Photo library access was denied"
            }
        }
    }
}
