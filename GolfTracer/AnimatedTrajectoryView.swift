import AVFoundation
import AVKit
import ImageIO
import SwiftUI
import UIKit

@MainActor
final class TrajectoryPlaybackController: ObservableObject {
    @Published var currentTime: CMTime = .zero
    @Published var isPlaying: Bool = false
    let player: AVPlayer
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init(url: URL) {
        let player = AVPlayer(url: url)
        self.player = player
        let interval = CMTime(value: 1, timescale: 60)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = time
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }
    }

    func togglePlay() {
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    deinit {
        if let observer = timeObserver { player.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> Container {
        let view = Container()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: Container, context: Context) {}

    final class Container: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

struct AnimatedTrajectoryView: View {
    let videoURL: URL
    let trajectories: [BallTrajectory]
    let orientation: CGImagePropertyOrientation
    let aspectRatio: CGFloat
    let deceleration: Double
    let curveFactor: Double

    let tracerTheme: TracerTheme
    let tracerThickness: Double
    let tracerTailLength: Double

    @StateObject private var controller: TrajectoryPlaybackController

    init(
        videoURL: URL,
        trajectories: [BallTrajectory],
        orientation: CGImagePropertyOrientation,
        aspectRatio: CGFloat,
        deceleration: Double,
        curveFactor: Double,
        tracerTheme: TracerTheme,
        tracerThickness: Double,
        tracerTailLength: Double
    ) {
        self.videoURL = videoURL
        self.trajectories = trajectories
        self.orientation = orientation
        self.aspectRatio = aspectRatio
        self.deceleration = deceleration
        self.curveFactor = curveFactor
        self.tracerTheme = tracerTheme
        self.tracerThickness = tracerThickness
        self.tracerTailLength = tracerTailLength
        _controller = StateObject(wrappedValue: TrajectoryPlaybackController(url: videoURL))
    }

    var body: some View {
        PlayerLayerView(player: controller.player)
            .overlay {
                TimelineView(.animation) { _ in
                    Canvas { context, size in
                        let now = CMTimeGetSeconds(controller.currentTime)
                        for (index, trajectory) in trajectories.enumerated() {
                            drawProgressiveTrajectory(
                                trajectory,
                                currentSeconds: now,
                                in: context,
                                size: size,
                                curveFactor: curveFactor
                            )
                        }
                    }
                }
            }
            .overlay {
                playPauseOverlay
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onAppear {
                controller.player.play()
                controller.isPlaying = true
            }
    }

    private var playPauseOverlay: some View {
        VStack {
            Spacer()
            Button(action: controller.togglePlay) {
                Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 4)
            }
            .padding(.bottom, 12)
        }
    }

    private func drawProgressiveTrajectory(
        _ trajectory: BallTrajectory,
        currentSeconds: Double,
        in context: GraphicsContext,
        size: CGSize,
        curveFactor: Double
    ) {
        let start = CMTimeGetSeconds(trajectory.timeRange.start)
        let end = CMTimeGetSeconds(trajectory.timeRange.end)
        guard currentSeconds >= start else { return }

        let linearProgress: Double = currentSeconds >= end
            ? 1.0
            : (currentSeconds - start) / max(end - start, 0.0001)

        let globalAlpha: Double = currentSeconds > end
            ? max(0.0, 1.0 - (currentSeconds - end) / 0.2)
            : 1.0
            
        guard globalAlpha > 0 else { return }

        // The points generated by TrajectoryAnalyzer are already physically accurate (Standard Parabola).
        // Sweeping through them linearly matches gravity perfectly.
        let progress = linearProgress

        let totalPoints = trajectory.points.count
        guard totalPoints > 0 else { return }
        
        let visibleCount = max(1, min(totalPoints, Int(Double(totalPoints) * progress)))
        
        // Calculate how many points to show based on tail length
        let maxTailPoints = Int(Double(totalPoints) * tracerTailLength)
        let startIndex = max(0, visibleCount - maxTailPoints)
        
        let visiblePoints = trajectory.points[startIndex..<visibleCount]
        let pointCount = visiblePoints.count
        guard pointCount > 1 else { return }

        let cgPoints = visiblePoints.map { rawPoint in
            uprightPoint(rawX: rawPoint.x, rawY: rawPoint.y, size: size)
        }
        guard let first = cgPoints.first else { return }

        let themeColors = tracerTheme.colors
        
        // Draw the tail fading out
        for i in 1..<pointCount {
            let p1 = cgPoints[i - 1]
            let p2 = cgPoints[i]
            
            let segmentProgress = Double(i) / Double(pointCount)
            
            let thickness = (tracerThickness * 0.3) + (tracerThickness * 0.7 * segmentProgress)
            let alpha = pow(segmentProgress, 2.0) * globalAlpha 
            
            // Map segmentProgress to a color in the gradient
            let colorIndex = segmentProgress * Double(themeColors.count - 1)
            let lowerIdx = min(themeColors.count - 1, Int(floor(colorIndex)))
            let upperIdx = min(themeColors.count - 1, Int(ceil(colorIndex)))
            let colorFraction = colorIndex - Double(lowerIdx)
            
            // Very simple color mix (GraphicsContext stroke handles it if we just pick the nearest color or we can let SwiftUI interpolate if we use a linear gradient along the path)
            // But since we are drawing segments, we just use the upper color for simplicity, or we can use a resolved color.
            // For now, let's just use the theme colors directly. To blend, we could write a blender, but let's just snap to the closest index.
            let resolvedColor = themeColors[Int(round(colorIndex))]
            
            var segmentPath = Path()
            segmentPath.move(to: p1)
            segmentPath.addLine(to: p2)
            
            // Outer glow
            context.stroke(segmentPath, with: .color(resolvedColor.opacity(alpha * 0.4)), lineWidth: thickness * 2.5)
            // Core line
            context.stroke(segmentPath, with: .color(resolvedColor.opacity(alpha)), lineWidth: thickness)
        }
        
        // Draw a tiny bright tip at the very head of the tracer
        if let lead = cgPoints.last {
            let resolvedColor = themeColors.last ?? .white
            let tip = Path(ellipseIn: CGRect(x: lead.x - tracerThickness/2, y: lead.y - tracerThickness/2, width: tracerThickness, height: tracerThickness))
            context.fill(tip, with: .color(resolvedColor.opacity(globalAlpha)))
        }
    }

    private func uprightPoint(rawX: CGFloat, rawY: CGFloat, size: CGSize) -> CGPoint {
        let (uX, uY): (CGFloat, CGFloat)
        switch orientation {
        case .right:
            uX = rawY
            uY = 1 - rawX
        case .left:
            uX = 1 - rawY
            uY = rawX
        case .down:
            uX = 1 - rawX
            uY = 1 - rawY
        default:
            uX = rawX
            uY = rawY
        }
        return CGPoint(x: uX * size.width, y: (1 - uY) * size.height)
    }
}
