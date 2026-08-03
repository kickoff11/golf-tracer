import AVKit
import Combine
import PhotosUI
import SwiftUI

enum TracerState {
    case idle
    case tappingStart
    case tappingApex
    case tappingEnd
    case confirming
    case tweaking
}

enum TracerTheme: String, CaseIterable, Identifiable {
    case fire = "Fire"
    case ice = "Ice"
    case classic = "Classic Red"
    case trackman = "Trackman Orange"
    
    var id: String { self.rawValue }
    
    var colors: [Color] {
        switch self {
        case .fire: return [.white, .yellow, .orange, .red, .clear]
        case .ice: return [.white, .cyan, .blue, .clear]
        case .classic: return [.red, .clear]
        case .trackman: return [.orange, .clear]
        }
    }
}

@MainActor
class GolfTracerViewModel: ObservableObject {
    @Published var selectedItem: PhotosPickerItem? = nil
    @Published var videoURL: URL? = nil {
        didSet {
            if let url = videoURL {
                Task {
                    await prepareVideo(url: url)
                }
            }
        }
    }
    @Published var showPicker = false
    @Published var isLoading = false
    @Published var showAllTrajectories = false
    
    // Custom Player and Scrubber states
    @Published var player: AVPlayer? = nil
    @Published var currentPlayerTime: Double = 0.0
    @Published var videoDuration: Double = 0.0
    @Published var isPlayingVideo = false
    @Published var isScrubbing = false
    
    // Manual Tap-to-Trace states
    @Published var startPoint: CGPoint? = nil
    @Published var apexPoint: CGPoint? = nil
    @Published var endPoint: CGPoint? = nil
    @Published var isTrajectoryConfirmed: Bool = false
    @Published var startTime: Double? = nil
    @Published var endTime: Double? = nil
    @Published var deceleration: Double = 0.55
    @Published var curveFactor: Double = 1.00
    
    // Customization States
    @Published var tracerTheme: TracerTheme = .fire
    @Published var tracerThickness: Double = 6.0
    @Published var tracerTailLength: Double = 1.0 // 0.1 (short) to 1.0 (long)
    @Published var showPreFlightGuide: Bool = true
    
    // Zoom & Pan states
    @Published var viewScale: CGFloat = 1.0
    @Published var lastViewScale: CGFloat = 1.0
    @Published var viewOffset: CGSize = .zero
    @Published var lastViewOffset: CGSize = .zero
    
    @Published var analyzer = TrajectoryAnalyzer()
    @Published var exporter = TrajectoryVideoExporter()

    private var playerObserver: Any? = nil
    private var playerNotificationToken: NSObjectProtocol? = nil
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        analyzer.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
            
        exporter.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
    
    var currentState: TracerState {
        if videoURL == nil { return .idle }
        if startPoint == nil { return .tappingStart }
        if apexPoint == nil { return .tappingApex }
        if endPoint == nil { return .tappingEnd }
        if !isTrajectoryConfirmed { return .confirming }
        return .tweaking
    }
    
    var hasResult: Bool {
        analyzer.stillFrame != nil && !analyzer.trajectories.isEmpty
    }
    
    var displayedTrajectories: [BallTrajectory] {
        showAllTrajectories
            ? analyzer.trajectories
            : analyzer.bestTrajectory.map { [$0] } ?? []
    }
    
    func constrainOffset(_ offset: CGSize, scale: CGFloat) -> CGSize {
        let screenW = UIScreen.main.bounds.width
        let videoAspect = analyzer.stillFrame.map { $0.size.width / $0.size.height } ?? (16.0 / 9.0)
        let videoH = screenW / videoAspect
        
        let maxOffsetX = screenW * (scale - 1.0) / 2.0
        let maxOffsetY = videoH * (scale - 1.0) / 2.0
        
        return CGSize(
            width: min(max(offset.width, -maxOffsetX), maxOffsetX),
            height: min(max(offset.height, -maxOffsetY), maxOffsetY)
        )
    }
    
    func handleTap(at location: CGPoint, in size: CGSize) {
        guard !isPlayingVideo else {
            player?.pause()
            isPlayingVideo = false
            return
        }

        let normalized = CGPoint(
            x: location.x / size.width,
            y: location.y / size.height
        )
        let rawPt = denormalizeTapPoint(normalized, orientation: analyzer.sourceOrientation)

        switch currentState {
        case .idle, .confirming:
            clearPoints()
            startPoint = rawPt
            startTime = currentPlayerTime
        case .tappingStart:
            startPoint = rawPt
            startTime = currentPlayerTime
        case .tappingApex:
            apexPoint = rawPt
        case .tappingEnd:
            endPoint = rawPt
            endTime = currentPlayerTime
            generateTrajectory()
        case .tweaking:
            break
        }
    }
    
    func togglePlayPause() {
        guard let player = player else { return }
        if isPlayingVideo {
            player.pause()
            isPlayingVideo = false
        } else {
            player.play()
            isPlayingVideo = true
        }
    }

    func clearPoints() {
        startPoint = nil
        apexPoint = nil
        endPoint = nil
        isTrajectoryConfirmed = false
        startTime = nil
        endTime = nil
        analyzer.trajectories = []
        currentPlayerTime = 0.0
        
        player?.pause()
        isPlayingVideo = false
        
        if let observer = playerObserver {
            player?.removeTimeObserver(observer)
            playerObserver = nil
        }
        if let token = playerNotificationToken {
            NotificationCenter.default.removeObserver(token)
            playerNotificationToken = nil
        }
        player?.seek(to: .zero)
    }

    func resetZoom() {
        withAnimation {
            viewScale = 1.0
            lastViewScale = 1.0
            viewOffset = .zero
            lastViewOffset = .zero
        }
    }
    
    func reset() {
        clearPoints()
        resetZoom()
    }

    func generateTrajectory() {
        guard let start = startPoint, let apex = apexPoint, let end = endPoint,
              let startT = startTime, let endT = endTime else { return }
        
        let trajectory = analyzer.generateManualTrajectory(
            startPoint: start,
            apexPoint: apex,
            endPoint: end,
            startTime: startT,
            endTime: endT,
            deceleration: deceleration,
            curveFactor: curveFactor,
            orientation: analyzer.sourceOrientation
        )
        analyzer.trajectories = [trajectory]
    }
    
    func confirmTrajectory() {
        isTrajectoryConfirmed = true
        viewScale = 1.0
        lastViewScale = 1.0
        viewOffset = .zero
        lastViewOffset = .zero
        generateTrajectory()
    }

    func prepareVideo(url: URL) async {
        await MainActor.run { isLoading = true }
        defer { Task { @MainActor in self.isLoading = false } }
        
        await MainActor.run {
            player?.pause()
            player = nil
            analyzer.trajectories = []
            analyzer.setupInfo = nil
            clearPoints()
        }

        let asset = AVURLAsset(url: url)
        do {
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
            let transform = try await track.load(.preferredTransform)
            let orientation = cgOrientation(from: transform)

            let duration = try await asset.load(.duration)
            let setupTime = CMTimeMultiplyByFloat64(duration, multiplier: 0.15)
            let still = try? await TrajectoryAnalyzer.extractFrame(from: url, at: setupTime)
            
            var setup = try? await SetupDetector.detectSetup(in: url, at: setupTime)
            if setup?.estimatedBallPosition == nil {
                setup = try? await SetupDetector.detectSetup(in: url, at: .zero)
            }
            if setup == nil {
                setup = SetupDetector.SetupInfo(personBoundingBox: nil, clubHeadRegion: nil, estimatedBallPosition: CGPoint(x: 0.5, y: 0.2), clubShaftLine: nil)
            } else if setup?.estimatedBallPosition == nil {
                setup?.estimatedBallPosition = CGPoint(x: 0.5, y: 0.2)
            }
            
            await MainActor.run {
                clearPoints()
                
                analyzer.sourceOrientation = orientation
                analyzer.stillFrame = still
                analyzer.setupInfo = setup
                analyzer.trajectories = []
                
                if let setupInfo = setup, let ballPos = setupInfo.estimatedBallPosition {
                    // ballPos is in Upright Vision coordinates.
                    // Convert it to normalized screen tap space: x = ballPos.x, y = 1 - ballPos.y
                    let screenTap = CGPoint(x: ballPos.x, y: 1.0 - ballPos.y)
                    // denormalize to Native Landscape coordinate
                    startPoint = denormalizeTapPoint(screenTap, orientation: orientation)
                    startTime = CMTimeGetSeconds(setupTime)
                }
                
                videoDuration = CMTimeGetSeconds(duration)
                
                let newPlayer = AVPlayer(url: url)
                let interval = CMTime(value: 1, timescale: 30)
                playerObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak newPlayer] time in
                    guard let self = self, let _ = newPlayer else { return }
                    if !self.isScrubbing {
                        self.currentPlayerTime = CMTimeGetSeconds(time)
                    }
                }
                
                playerNotificationToken = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: newPlayer.currentItem,
                    queue: .main
                ) { [weak self, weak newPlayer] _ in
                    newPlayer?.seek(to: .zero)
                    newPlayer?.pause()
                    self?.isPlayingVideo = false
                }
                
                player = newPlayer
                isPlayingVideo = false
            }
        } catch {
            print("Error preparing video: \(error)")
        }
    }

    func runExport() {
        guard let url = videoURL, !analyzer.trajectories.isEmpty else { return }
        Task {
            await exporter.export(
                videoURL: url,
                trajectories: displayedTrajectories,
                orientation: analyzer.sourceOrientation,
                deceleration: deceleration,
                curveFactor: curveFactor,
                tracerTheme: tracerTheme,
                tracerThickness: tracerThickness,
                tracerTailLength: tracerTailLength
            )
        }
    }

    private func denormalizeTapPoint(_ tapPoint: CGPoint, orientation: CGImagePropertyOrientation) -> CGPoint {
        let rawX: CGFloat
        let rawY: CGFloat
        switch orientation {
        case .right:
            rawX = tapPoint.y
            rawY = tapPoint.x
        case .left:
            rawX = 1.0 - tapPoint.y
            rawY = 1.0 - tapPoint.x
        case .down:
            rawX = 1.0 - tapPoint.x
            rawY = 1.0 - tapPoint.y
        default:
            rawX = tapPoint.x
            rawY = tapPoint.y
        }
        return CGPoint(x: rawX, y: rawY)
    }

    func uprightPoint(rawPoint: CGPoint, in size: CGSize) -> CGPoint {
        let orientation = analyzer.sourceOrientation
        let (uX, uY): (CGFloat, CGFloat)
        switch orientation {
        case .right:
            uX = rawPoint.y
            uY = 1 - rawPoint.x
        case .left:
            uX = 1 - rawPoint.y
            uY = rawPoint.x
        case .down:
            uX = 1 - rawPoint.x
            uY = 1 - rawPoint.y
        default:
            uX = rawPoint.x
            uY = rawPoint.y
        }
        return CGPoint(x: uX * size.width, y: (1 - uY) * size.height)
    }

    private func cgOrientation(from transform: CGAffineTransform) -> CGImagePropertyOrientation {
        if transform.a == 0 && transform.b ==  1 && transform.c == -1 && transform.d == 0 { return .right }
        if transform.a == 0 && transform.b == -1 && transform.c ==  1 && transform.d == 0 { return .left  }
        if transform.a == -1 && transform.b == 0 && transform.c ==  0 && transform.d == -1 { return .down }
        return .up
    }
}
