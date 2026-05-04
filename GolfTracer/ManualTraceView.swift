import AVFoundation
import AVKit
import SwiftUI

@MainActor
final class ManualTraceController: ObservableObject {
    @Published var currentSeconds: Double = 0
    @Published var duration: Double = 0
    @Published var trajectory = ManualTrajectory()
    let player: AVPlayer
    private var timeObserver: Any?

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        self.player = AVPlayer(playerItem: item)
        player.pause()

        Task { [weak self] in
            let seconds = CMTimeGetSeconds(try await item.asset.load(.duration))
            await MainActor.run { self?.duration = seconds }
        }

        let interval = CMTime(value: 1, timescale: 60)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentSeconds = CMTimeGetSeconds(time)
        }
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func recordTap(at normalizedPoint: CGPoint) {
        let time = CMTime(seconds: currentSeconds, preferredTimescale: 600)
        trajectory.add(ManualTap(time: time, normalizedPoint: normalizedPoint))
    }

    deinit {
        if let observer = timeObserver { player.removeTimeObserver(observer) }
    }
}

struct ManualTraceView: View {
    let videoURL: URL
    let aspectRatio: CGFloat
    let onDone: (ManualTrajectory) -> Void
    let onCancel: () -> Void

    @StateObject private var controller: ManualTraceController

    init(
        videoURL: URL,
        aspectRatio: CGFloat,
        onDone: @escaping (ManualTrajectory) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.videoURL = videoURL
        self.aspectRatio = aspectRatio
        self.onDone = onDone
        self.onCancel = onCancel
        _controller = StateObject(wrappedValue: ManualTraceController(url: videoURL))
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Tap the ball at 3+ moments during its flight. Use the slider to scrub between frames.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            videoArea

            scrubber

            actionRow
        }
        .padding()
    }

    private var videoArea: some View {
        GeometryReader { geo in
            ZStack {
                PlayerLayerView(player: controller.player)
                ForEach(controller.trajectory.taps.indices, id: \.self) { index in
                    let tap = controller.trajectory.taps[index]
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1))
                        .position(
                            x: tap.normalizedPoint.x * geo.size.width,
                            y: tap.normalizedPoint.y * geo.size.height
                        )
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let normalized = CGPoint(
                    x: max(0, min(1, location.x / geo.size.width)),
                    y: max(0, min(1, location.y / geo.size.height))
                )
                controller.recordTap(at: normalized)
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { controller.currentSeconds },
                    set: { controller.seek(to: $0) }
                ),
                in: 0...max(controller.duration, 0.0001)
            )
            HStack {
                Text(String(format: "%.2f s", controller.currentSeconds))
                    .font(.caption.monospacedDigit())
                Spacer()
                Text("\(controller.trajectory.taps.count) tap\(controller.trajectory.taps.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button("Cancel") { onCancel() }
                .buttonStyle(.bordered)

            Button("Undo") { controller.trajectory.removeLast() }
                .buttonStyle(.bordered)
                .disabled(controller.trajectory.taps.isEmpty)

            Button("Clear") { controller.trajectory.clear() }
                .buttonStyle(.bordered)
                .disabled(controller.trajectory.taps.isEmpty)

            Spacer()

            Button("Done") { onDone(controller.trajectory) }
                .buttonStyle(.borderedProminent)
                .disabled(controller.trajectory.taps.count < 3)
        }
    }
}
