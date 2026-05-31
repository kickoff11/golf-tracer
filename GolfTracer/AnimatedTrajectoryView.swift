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

    @StateObject private var controller: TrajectoryPlaybackController

    init(
        videoURL: URL,
        trajectories: [BallTrajectory],
        orientation: CGImagePropertyOrientation,
        aspectRatio: CGFloat
    ) {
        self.videoURL = videoURL
        self.trajectories = trajectories
        self.orientation = orientation
        self.aspectRatio = aspectRatio
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
        let start = CMTimeGetSeconds(trajectory.timeRange.start)
        let end = CMTimeGetSeconds(trajectory.timeRange.end)
        guard currentSeconds >= start else { return }

        let progress: Double = currentSeconds >= end
            ? 1.0
            : (currentSeconds - start) / max(end - start, 0.0001)

        let totalPoints = trajectory.points.count
        guard totalPoints > 0 else { return }
        let visibleCount = max(1, min(totalPoints, Int(Double(totalPoints) * progress)))
        let visiblePoints = trajectory.points.prefix(visibleCount)

        let cgPoints = visiblePoints.map { rawPoint in
            uprightPoint(rawX: rawPoint.x, rawY: rawPoint.y, size: size)
        }
        guard let first = cgPoints.first else { return }

        var path = Path()
        path.move(to: first)
        for point in cgPoints.dropFirst() {
            path.addLine(to: point)
        }
        context.stroke(path, with: .color(color.opacity(0.4)), lineWidth: 10)
        context.stroke(path, with: .color(color), lineWidth: 3)

        if let lead = cgPoints.last {
            let dot = Path(ellipseIn: CGRect(x: lead.x - 5, y: lead.y - 5, width: 10, height: 10))
            context.fill(dot, with: .color(color))
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
