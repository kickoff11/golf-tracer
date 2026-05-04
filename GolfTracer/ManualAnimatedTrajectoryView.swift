import AVFoundation
import AVKit
import SwiftUI

struct ManualAnimatedTrajectoryView: View {
    let videoURL: URL
    let trajectory: ManualTrajectory
    let aspectRatio: CGFloat

    @StateObject private var controller: TrajectoryPlaybackController

    init(videoURL: URL, trajectory: ManualTrajectory, aspectRatio: CGFloat) {
        self.videoURL = videoURL
        self.trajectory = trajectory
        self.aspectRatio = aspectRatio
        _controller = StateObject(wrappedValue: TrajectoryPlaybackController(url: videoURL))
    }

    private var fittedSamples: [ManualTrajectory.FittedSample] {
        trajectory.fittedDensePoints()
    }

    var body: some View {
        ZStack {
            PlayerLayerView(player: controller.player)
            Canvas { context, size in
                let now = CMTimeGetSeconds(controller.currentTime)
                drawProgressive(in: context, size: size, currentSeconds: now)
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

    private func drawProgressive(in context: GraphicsContext, size: CGSize, currentSeconds: Double) {
        let samples = fittedSamples
        guard samples.count > 1 else { return }

        let visible = samples.filter { CMTimeGetSeconds($0.time) <= currentSeconds }
        guard visible.count > 1 else { return }

        let cgPoints = visible.map { sample in
            CGPoint(
                x: sample.point.x * size.width,
                y: sample.point.y * size.height
            )
        }

        var path = Path()
        path.move(to: cgPoints.first!)
        for point in cgPoints.dropFirst() {
            path.addLine(to: point)
        }
        context.stroke(path, with: .color(.yellow.opacity(0.45)), lineWidth: 12)
        context.stroke(path, with: .color(.yellow), lineWidth: 4)

        if let lead = cgPoints.last {
            let dot = Path(ellipseIn: CGRect(x: lead.x - 7, y: lead.y - 7, width: 14, height: 14))
            context.fill(dot, with: .color(.yellow))
            context.stroke(dot, with: .color(.black.opacity(0.7)), lineWidth: 1.5)
        }
    }
}
