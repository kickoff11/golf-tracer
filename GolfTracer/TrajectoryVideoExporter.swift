import AVFoundation
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
            let outputURL = try await renderAnnotated(videoURL: videoURL, trajectory: trajectory)
            try await saveToPhotos(url: outputURL)
            status = .savedToPhotos
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func renderAnnotated(videoURL: URL, trajectory: ManualTrajectory) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        let renderSize = composition.renderSize

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.isGeometryFlipped = true  // top-left origin so taps line up

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(videoLayer)

        let trajectoryLayer = makeTrajectoryLayer(trajectory: trajectory, size: renderSize)
        parentLayer.addSublayer(trajectoryLayer)

        composition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.cannotCreateExporter
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        exporter.videoComposition = composition
        exporter.shouldOptimizeForNetworkUse = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                if exporter.status == .completed {
                    continuation.resume()
                } else if let error = exporter.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: ExportError.exportFailed(exporter.status.rawValue))
                }
            }
        }
        return outputURL
    }

    private func makeTrajectoryLayer(trajectory: ManualTrajectory, size: CGSize) -> CAShapeLayer {
        let shapeLayer = CAShapeLayer()
        shapeLayer.frame = CGRect(origin: .zero, size: size)
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.strokeColor = UIColor.systemYellow.cgColor
        shapeLayer.lineWidth = max(6, size.width * 0.006)
        shapeLayer.lineCap = .round
        shapeLayer.lineJoin = .round
        shapeLayer.shadowColor = UIColor.black.cgColor
        shapeLayer.shadowOpacity = 0.6
        shapeLayer.shadowOffset = CGSize(width: 0, height: 2)
        shapeLayer.shadowRadius = 4

        let samples = trajectory.fittedDensePoints()
        guard samples.count > 1 else { return shapeLayer }

        let path = UIBezierPath()
        let cgPoints = samples.map { sample in
            CGPoint(x: sample.point.x * size.width, y: sample.point.y * size.height)
        }
        path.move(to: cgPoints.first!)
        for point in cgPoints.dropFirst() {
            path.addLine(to: point)
        }
        shapeLayer.path = path.cgPath
        shapeLayer.strokeEnd = 0  // initially hidden

        let sortedTaps = trajectory.sortedTaps
        guard let first = sortedTaps.first?.time, let last = sortedTaps.last?.time else {
            return shapeLayer
        }
        let startSecs = CMTimeGetSeconds(first)
        let endSecs = CMTimeGetSeconds(last)
        let duration = max(endSecs - startSecs, 0.001)

        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = duration
        animation.beginTime = AVCoreAnimationBeginTimeAtZero + startSecs
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        shapeLayer.add(animation, forKey: "strokeEnd")

        return shapeLayer
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
        case cannotCreateExporter
        case exportFailed(Int)
        case photosAccessDenied

        var errorDescription: String? {
            switch self {
            case .cannotCreateExporter: return "Could not create export session"
            case .exportFailed(let code): return "Export failed (status \(code))"
            case .photosAccessDenied: return "Photo library access was denied"
            }
        }
    }
}
