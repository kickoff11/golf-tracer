import AVFoundation
import CoreGraphics
import CoreMedia
import ImageIO
import Foundation

/// Finds candidate golf-ball positions in footage shot from a locked-off tripod.
///
/// Why this beats Apple's generic trajectory detector for this kind of footage:
/// when the camera never moves, the background is the same pixels in every frame, so
/// subtracting one frame from the one before it makes the static scenery vanish and
/// leaves only things that *moved* — overwhelmingly the ball (plus the club and the
/// golfer for a moment). Among the moving pixels we then keep the ones that are bright
/// and colourless, i.e. white like a golf ball. That gives a short list of "the ball
/// might be here" guesses for every frame.
///
/// This stage deliberately errs toward catching too much (it may also flag the club
/// head, a shiny shoe, a fluttering leaf). It does NOT try to be clever about which
/// guess is the real ball — that job belongs to `TrajectoryFitter`, which keeps only
/// the guesses that line up into a single gravity-shaped arc.
///
/// The numeric thresholds below are first estimates. They are the knobs to turn once a
/// real 60-frames-per-second clip is available to test against.
enum StaticCameraBallDetector {

    struct Result {
        let samples: [TrajectoryFitter.Sample]   // candidate positions, normalised bottom-left
        let orientation: CGImagePropertyOrientation
        let nominalFPS: Float?
        let videoDuration: CMTime?
    }

    // MARK: – Tunable detection knobs

    /// How much a pixel's brightness must change between frames to count as "moving",
    /// on a 0...255 scale. Lower catches fainter motion but lets in more noise.
    private static let motionThreshold: Double = 16

    /// Minimum combined motion×whiteness score for a pixel to be a ball candidate.
    private static let scoreThreshold: Double = 0.03

    /// Most ball guesses to keep per frame. The fitter discards the wrong ones.
    private static let candidatesPerFrame = 6

    // MARK: – Detection

    static func detect(in url: URL) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return Result(samples: [], orientation: .up, nominalFPS: nil, videoDuration: nil)
            }

            let transform = try await track.load(.preferredTransform)
            let fps        = try await track.load(.nominalFrameRate)
            let duration   = try await asset.load(.duration)
            let orientation = cgOrientation(from: transform)

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            )
            output.alwaysCopiesSampleData = false
            reader.add(output)
            reader.startReading()

            var samples: [TrajectoryFitter.Sample] = []
            var previous: [Double] = []      // brightness of the prior frame, on the strided grid
            var gridW = 0, gridH = 0, stride = 1

            while let sample = output.copyNextSampleBuffer() {
                let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }

                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddress(buffer) else { continue }

                let width  = CVPixelBufferGetWidth(buffer)
                let height = CVPixelBufferGetHeight(buffer)
                let bpr    = CVPixelBufferGetBytesPerRow(buffer)
                let ptr    = base.assumingMemoryBound(to: UInt8.self)

                // Process a coarser grid on very large (4K) frames to keep it fast; a
                // ball is still several grid cells wide.
                if previous.isEmpty {
                    stride = max(1, min(2, height / 1080))
                    gridW = width  / stride
                    gridH = height / stride
                    previous = [Double](repeating: -1, count: gridW * gridH)
                }

                var hot: [(score: Double, gx: Int, gy: Int)] = []
                hot.reserveCapacity(1024)

                for gy in 0..<gridH {
                    let py = gy * stride
                    let rowBase = py * bpr
                    let prevRow = gy * gridW
                    for gx in 0..<gridW {
                        let px = gx * stride
                        let o = rowBase + px * 4
                        let b = Double(ptr[o])       // BGRA byte order
                        let g = Double(ptr[o + 1])
                        let r = Double(ptr[o + 2])
                        let bright = (r + g + b) / 3.0

                        let gi = prevRow + gx
                        let prev = previous[gi]
                        previous[gi] = bright
                        if prev < 0 { continue }      // first frame: just record brightness

                        let motion = abs(bright - prev)
                        if motion < motionThreshold { continue }

                        // Whiteness: bright and colourless (small spread between channels).
                        let maxC = max(r, max(g, b))
                        let minC = min(r, min(g, b))
                        let whiteness = (bright / 255.0) * (1.0 - (maxC - minC) / 255.0)
                        let score = (motion / 255.0) * whiteness
                        if score >= scoreThreshold {
                            hot.append((score, gx, gy))
                        }
                    }
                }

                // Keep the strongest, well-separated peaks (non-maximum suppression).
                let peaks = suppress(hot, gridW: gridW, gridH: gridH,
                                     keep: candidatesPerFrame, stride: stride, height: height)
                for p in peaks {
                    // Pixel centre → normalised, bottom-left origin (x right, y up).
                    let xN = (Double(p.gx * stride) + Double(stride) / 2) / Double(width)
                    let yN = 1.0 - (Double(p.gy * stride) + Double(stride) / 2) / Double(height)
                    samples.append(TrajectoryFitter.Sample(point: CGPoint(x: xN, y: yN), time: time))
                }
            }

            return Result(samples: samples, orientation: orientation,
                          nominalFPS: fps, videoDuration: duration)
        }.value
    }

    /// Greedily keep the highest-scoring pixels while suppressing their neighbours, so a
    /// single bright blob yields one point rather than dozens. Also drops blobs that are
    /// far too large to be a ball (the golfer's body, big shadows).
    private static func suppress(
        _ hot: [(score: Double, gx: Int, gy: Int)],
        gridW: Int, gridH: Int, keep: Int, stride: Int, height: Int
    ) -> [(gx: Int, gy: Int)] {
        guard !hot.isEmpty else { return [] }
        let sorted = hot.sorted { $0.score > $1.score }.prefix(2000)

        // Ball radius limits (at most 5% of frame height), in grid cells.
        let maxRadiusGrid = max(2, Int((0.05 * Double(height)) / Double(stride)))
        let suppressR = maxRadiusGrid
        let suppressR2 = suppressR * suppressR

        var picked: [(gx: Int, gy: Int)] = []
        var taken: [(gx: Int, gy: Int)] = []
        for h in sorted {
            if picked.count >= keep { break }
            var blocked = false
            for t in taken {
                let dx = h.gx - t.gx, dy = h.gy - t.gy
                if dx * dx + dy * dy <= suppressR2 { blocked = true; break }
            }
            if blocked { continue }

            // Reject regions that are clearly too big to be a ball: count how many hot
            // pixels crowd a tight window around this peak.
            let tightR = max(1, maxRadiusGrid / 2)
            let tightR2 = tightR * tightR
            var crowd = 0
            for other in sorted {
                let dx = other.gx - h.gx, dy = other.gy - h.gy
                if dx * dx + dy * dy <= tightR2 { crowd += 1 }
            }
            let windowArea = Double(tightR2) * Double.pi
            if Double(crowd) > windowArea * 0.7 { taken.append((h.gx, h.gy)); continue }

            picked.append((h.gx, h.gy))
            taken.append((h.gx, h.gy))
        }
        return picked
    }
}

private func cgOrientation(from transform: CGAffineTransform) -> CGImagePropertyOrientation {
    if transform.a == 0 && transform.b ==  1 && transform.c == -1 && transform.d == 0 { return .right }
    if transform.a == 0 && transform.b == -1 && transform.c ==  1 && transform.d == 0 { return .left  }
    if transform.a == -1 && transform.b == 0 && transform.c ==  0 && transform.d == -1 { return .down }
    return .up
}
