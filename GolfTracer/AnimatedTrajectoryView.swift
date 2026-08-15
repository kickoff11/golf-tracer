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
            Task { @MainActor [weak self] in self?.currentTime = time }
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
    let trailLength: Double

    @StateObject private var controller: TrajectoryPlaybackController

    init(
        videoURL: URL,
        trajectories: [BallTrajectory],
        orientation: CGImagePropertyOrientation,
        aspectRatio: CGFloat,
        deceleration: Double,
        curveFactor: Double,
        trailLength: Double
    ) {
        self.videoURL = videoURL
        self.trajectories = trajectories
        self.orientation = orientation
        self.aspectRatio = aspectRatio
        self.deceleration = deceleration
        self.curveFactor = curveFactor
        self.trailLength = trailLength
        _controller = StateObject(wrappedValue: TrajectoryPlaybackController(url: videoURL))
    }

    var body: some View {
        ZStack {
            PlayerLayerView(player: controller.player)
            Canvas { context, size in
                let now = CMTimeGetSeconds(controller.currentTime)
                for (index, trajectory) in trajectories.enumerated() {
                    let color = Self.colors[index % Self.colors.count]
                    drawProgressiveTrajectory(
                        trajectory,
                        currentSeconds: now,
                        in: context,
                        size: size,
                        color: color
                    )
                }
            }
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

    private static let colors: [Color] = [.red, .yellow, .cyan, .green, .orange, .pink]

    private func drawProgressiveTrajectory(
        _ trajectory: BallTrajectory,
        currentSeconds: Double,
        in context: GraphicsContext,
        size: CGSize,
        color: Color
    ) {
        guard let frame = TrajectoryRenderMath.frame(
            at: currentSeconds,
            trajectory: trajectory,
            curve: curveFactor,
            trailLength: trailLength
        ) else { return }
        let visiblePoints = trajectory.points[frame.pointRange]

        let cgPoints = visiblePoints.map { rawPoint in
            uprightPoint(rawX: rawPoint.x, rawY: rawPoint.y, size: size)
        }
        let pointCount = cgPoints.count
        guard pointCount > 1 else { return }
        
        for i in 1..<pointCount {
            let p1 = cgPoints[i - 1]
            let p2 = cgPoints[i]
            
            let alpha = TrajectoryRenderMath.segmentAlpha(index: i, count: pointCount, globalAlpha: frame.globalAlpha)
            
            if alpha < 0.02 { continue }
            
            var segmentPath = Path()
            segmentPath.move(to: p1)
            segmentPath.addLine(to: p2)
            
            let thickness = TrajectoryRenderMath.segmentWidth(index: i, count: pointCount)
            
            context.stroke(segmentPath, with: .color(color.opacity(alpha * 0.4)), lineWidth: thickness * 3)
            context.stroke(segmentPath, with: .color(color.opacity(alpha)), lineWidth: thickness)
        }

        if let lead = cgPoints.last {
            let dot = Path(ellipseIn: CGRect(x: lead.x - 5, y: lead.y - 5, width: 10, height: 10))
            context.fill(dot, with: .color(color.opacity(frame.globalAlpha)))
        }
    }

    private func uprightPoint(rawX: CGFloat, rawY: CGFloat, size: CGSize) -> CGPoint {
        TrajectoryRenderMath.displayPoint(
            native: CGPoint(x: rawX, y: rawY),
            orientation: orientation,
            size: size
        )
    }
}
