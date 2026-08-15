import AVKit
import PhotosUI
import SwiftUI

struct ContentView: View {
    @State private var videoURL: URL?
    @State private var preparedURL: URL?
    @State private var showPicker = false
    @State private var isLoading = false
    
    // Custom Player and Scrubber states
    @State private var player: AVPlayer? = nil
    @State private var playerObserver: Any? = nil
    @State private var playerNotificationToken: NSObjectProtocol? = nil
    @State private var currentPlayerTime: Double = 0.0
    @State private var videoDuration: Double = 0.0
    @State private var nominalFrameRate: Double = 30.0
    @State private var isPlayingVideo = false
    @State private var isScrubbing = false
    
    // Manual Tap-to-Trace states
    @State private var startPoint: CGPoint? = nil
    @State private var apexPoint: CGPoint? = nil
    @State private var endPoint: CGPoint? = nil
    @State private var isTrajectoryConfirmed: Bool = false
    @State private var startTime: Double? = nil
    @State private var endTime: Double? = nil
    @State private var deceleration: Double = 0.55    // Apex Time (normalized)
    @State private var curveFactor: Double = 1.00     // S-Curve modifier
    @State private var trailLength: Double = 0.70
    
    // Zoom & Pan states
    @State private var viewScale: CGFloat = 1.0
    @State private var lastViewScale: CGFloat = 1.0
    @State private var viewOffset: CGSize = .zero
    @State private var lastViewOffset: CGSize = .zero
    
    @StateObject private var analyzer  = TrajectoryAnalyzer()
    @StateObject private var exporter  = TrajectoryVideoExporter()

    private var hasResult: Bool {
        analyzer.stillFrame != nil && !analyzer.trajectories.isEmpty
    }

    private var displayedTrajectories: [BallTrajectory] { analyzer.bestTrajectory.map { [$0] } ?? [] }

    var body: some View {
        NavigationStack {
            VStack(spacing: 4) {
                mainArea
                    .frame(maxHeight: .infinity)

                if let error = analyzer.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                controlsArea
                
                if case .failed(let msg) = exporter.status {
                    Text("Export failed: \(msg)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal)
            .navigationTitle("Golf Tracer")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPicker) {
                VideoPicker(videoURL: $videoURL, errorMessage: $analyzer.errorMessage)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        if hasResult {
                            if exporter.status == .exporting {
                                ProgressView()
                            } else {
                                Button(action: runExport) { Image(systemName: "square.and.arrow.down") }
                            }
                        }
                        Button { showPicker = true } label: { Image(systemName: "video.badge.plus") }
                    }
                }
                if hasResult {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Reset") {
                            clearPoints()
                            withAnimation {
                                viewScale = 1.0; lastViewScale = 1.0
                                viewOffset = .zero; lastViewOffset = .zero
                            }
                        }
                    }
                }
            }
            .onChange(of: videoURL) { _, newURL in
                if let url = newURL, preparedURL != url {
                    Task {
                        await prepareVideo(url: url)
                    }
                }
            }
            .task { await restoreProjectIfAvailable() }
        }
    }

    // MARK: – Main area

    @ViewBuilder
    private var mainArea: some View {
        if !analyzer.trajectories.isEmpty, let url = videoURL {
            let aspect = analyzer.stillFrame.map { $0.size.width / $0.size.height } ?? 9.0 / 16.0
            VStack(alignment: .leading, spacing: 8) {
                AnimatedTrajectoryView(
                    videoURL: url,
                    trajectories: displayedTrajectories,
                    orientation: analyzer.sourceOrientation,
                    aspectRatio: aspect,
                    deceleration: deceleration,
                    curveFactor: curveFactor,
                    trailLength: trailLength
                )
                .id(url.path + (analyzer.bestTrajectory?.id.uuidString ?? ""))
                .scaleEffect(viewScale)
                .offset(viewOffset)
                .gesture(
                    DragGesture()
                        .onChanged { val in
                            if viewScale > 1.0 {
                                let proposed = CGSize(
                                    width: lastViewOffset.width + val.translation.width,
                                    height: lastViewOffset.height + val.translation.height
                                )
                                viewOffset = constrainOffset(proposed, scale: viewScale)
                            }
                        }
                        .onEnded { val in
                            if viewScale > 1.0 {
                                lastViewOffset = viewOffset
                            }
                        }
                )
                .gesture(
                    MagnificationGesture()
                        .onChanged { val in 
                            viewScale = max(1.0, lastViewScale * val) 
                            viewOffset = constrainOffset(lastViewOffset, scale: viewScale)
                        }
                        .onEnded { val in 
                            lastViewScale = viewScale 
                            lastViewOffset = viewOffset
                        }
                )
                .clipped()
            }
        } else if videoURL != nil {
            VStack(spacing: 8) {
                ZStack {
                    if let player = player {
                        PlayerLayerView(player: player)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        GeometryReader { geo in
                            // Transparent overlay to receive taps (always active during setup)
                            Color.black.opacity(0.001) // very low opacity, receives taps
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    handleTap(at: location, in: geo.size)
                                }

                            // Start point marker (Tee)
                            if let start = startPoint {
                                let visualStart = uprightPoint(rawPoint: start, orientation: analyzer.sourceOrientation, in: geo.size)
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().stroke(Color.white, lineWidth: 1))
                                    .position(visualStart)
                                    .shadow(radius: 2)
                                    .gesture(DragGesture().onChanged { value in
                                        startPoint = pointFromDisplay(value.location, in: geo.size)
                                    })
                            }
                            
                            // Apex point marker
                            if let apex = apexPoint {
                                let visualApex = uprightPoint(rawPoint: apex, orientation: analyzer.sourceOrientation, in: geo.size)
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().stroke(Color.white, lineWidth: 1))
                                    .position(visualApex)
                                    .shadow(radius: 2)
                                    .gesture(DragGesture().onChanged { value in
                                        apexPoint = pointFromDisplay(value.location, in: geo.size)
                                    })
                            }
                            
                            // End point marker (Landing)
                            if let end = endPoint {
                                let visualEnd = uprightPoint(rawPoint: end, orientation: analyzer.sourceOrientation, in: geo.size)
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().stroke(Color.white, lineWidth: 1))
                                    .position(visualEnd)
                                    .shadow(radius: 2)
                                    .gesture(DragGesture().onChanged { value in
                                        endPoint = pointFromDisplay(value.location, in: geo.size)
                                    })
                            }
                        }
                    } else {
                        ProgressView("Preparing video…")
                    }
                }
                .aspectRatio(analyzer.stillFrame.map { $0.size.width / $0.size.height } ?? 16/9, contentMode: .fit)
                .scaleEffect(viewScale)
                .offset(viewOffset)
                .gesture(
                    DragGesture()
                        .onChanged { val in
                            if viewScale > 1.0 {
                                let proposed = CGSize(
                                    width: lastViewOffset.width + val.translation.width,
                                    height: lastViewOffset.height + val.translation.height
                                )
                                viewOffset = constrainOffset(proposed, scale: viewScale)
                            }
                        }
                        .onEnded { val in
                            if viewScale > 1.0 {
                                lastViewOffset = viewOffset
                            }
                        }
                )
                .gesture(
                    MagnificationGesture()
                        .onChanged { val in 
                            viewScale = max(1.0, lastViewScale * val)
                            viewOffset = constrainOffset(lastViewOffset, scale: viewScale)
                        }
                        .onEnded { val in 
                            lastViewScale = viewScale
                            lastViewOffset = viewOffset
                        }
                )
                .clipped()
                
                // Playback controls and scrubber slider
                if let player = player {
                    HStack(spacing: 12) {
                        Button(action: togglePlayPause) {
                            Image(systemName: isPlayingVideo ? "pause.fill" : "play.fill")
                                .font(.title3)
                                .padding(8)
                                .background(Color.accentColor.opacity(0.1))
                                .clipShape(Circle())
                        }

                        Button { stepFrame(-1) } label: {
                            Image(systemName: "backward.frame.fill")
                        }
                        .accessibilityLabel("Previous frame")
                        
                        Slider(value: $currentPlayerTime, in: 0...max(videoDuration, 0.1)) { editing in
                            isScrubbing = editing
                            if !editing {
                                player.seek(to: CMTime(seconds: currentPlayerTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                            }
                        }
                        .onChange(of: currentPlayerTime) { _, newValue in
                            if isScrubbing {
                                player.seek(to: CMTime(seconds: newValue, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                            }
                        }
                        
                        Text(String(format: "%.2f / %.2fs", currentPlayerTime, videoDuration))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)

                        Button { stepFrame(1) } label: {
                            Image(systemName: "forward.frame.fill")
                        }
                        .accessibilityLabel("Next frame")
                    }
                    .padding(.horizontal)
                }
            }
        } else if isLoading {
            placeholder { ProgressView("Loading video…") }
        } else {
            placeholder {
                VStack(spacing: 8) {
                    Image(systemName: "video")
                        .font(.system(size: 40))
                    Text("Pick a video to get started")
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: – Controls Area

    @ViewBuilder
    private var controlsArea: some View {
        if videoURL != nil {
            VStack(spacing: 8) {
                instructionsView
                if isTrajectoryConfirmed {
                    sliderArea
                }
            }
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var instructionsView: some View {
        HStack {
            if startPoint == nil {
                Text("Tap the Tee (Start)")
            } else if apexPoint == nil {
                Text("Tap the Apex (Highest)")
                Spacer()
                Button("Undo") { startPoint = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if endPoint == nil {
                Text("Tap the Landing (End)")
                Spacer()
                Button("Undo") { apexPoint = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if !isTrajectoryConfirmed {
                Text("Confirm Points?")
                Spacer()
                Button("Undo") { endPoint = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Generate") {
                    isTrajectoryConfirmed = true
                    generateTrajectory()
                    withAnimation {
                        viewScale = 1.0; lastViewScale = 1.0
                        viewOffset = .zero; lastViewOffset = .zero
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Text("Trajectory ready")
                Spacer()
                Button("Edit points") {
                    isTrajectoryConfirmed = false
                    analyzer.trajectories = []
                    currentPlayerTime = startTime ?? 0
                    player?.seek(to: CMTime(seconds: currentPlayerTime, preferredTimescale: 600))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Reset") {
                    clearPoints()
                    withAnimation {
                        viewScale = 1.0; lastViewScale = 1.0
                        viewOffset = .zero; lastViewOffset = .zero
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .font(.subheadline.bold())
        .padding(.horizontal)
    }

    private var sliderArea: some View {
        VStack(spacing: -8) {
            HStack {
                Text("Apex %:")
                    .font(.subheadline.bold())
                    .frame(width: 70, alignment: .leading)
                
                Button {
                    deceleration = max(0.10, deceleration - 0.01)
                    generateTrajectory()
                } label: { 
                    Image(systemName: "minus.square.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                Slider(value: $deceleration, in: 0.10...0.80)
                    .onChange(of: deceleration) { _, _ in
                        generateTrajectory()
                    }
                
                Button {
                    deceleration = min(0.80, deceleration + 0.01)
                    generateTrajectory()
                } label: { 
                    Image(systemName: "plus.square.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                Text(String(format: "%.2f", deceleration))
                    .monospacedDigit()
                    .font(.subheadline)
                    .frame(width: 45, alignment: .trailing)
            }

            HStack {
                Text("Trail:")
                    .font(.subheadline.bold())
                    .frame(width: 70, alignment: .leading)
                Slider(value: $trailLength, in: 0.15...1.0)
                    .onChange(of: trailLength) { _, _ in saveProject() }
                Text("\(Int(trailLength * 100))%")
                    .monospacedDigit()
                    .font(.subheadline)
                    .frame(width: 45, alignment: .trailing)
            }
            
            HStack {
                Text("Curve:")
                    .font(.subheadline.bold())
                    .frame(width: 70, alignment: .leading)
                
                Button {
                    curveFactor = max(0.70, curveFactor - 0.01)
                    generateTrajectory()
                } label: { 
                    Image(systemName: "minus.square.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                Slider(value: $curveFactor, in: 0.70...1.30)
                    .onChange(of: curveFactor) { _, _ in
                        generateTrajectory()
                    }
                
                Button {
                    curveFactor = min(1.30, curveFactor + 0.01)
                    generateTrajectory()
                } label: { 
                    Image(systemName: "plus.square.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                Text(String(format: "%.2f", curveFactor))
                    .monospacedDigit()
                    .font(.subheadline)
                    .frame(width: 45, alignment: .trailing)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Handlers
    
    private func constrainOffset(_ offset: CGSize, scale: CGFloat) -> CGSize {
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

    private func handleTap(at location: CGPoint, in size: CGSize) {
        guard !isPlayingVideo else {
            player?.pause()
            isPlayingVideo = false
            return
        }

        let normalized = CGPoint(
            x: location.x / size.width,
            y: 1.0 - (location.y / size.height)
        )
        let rawPt = denormalizeTapPoint(normalized, orientation: analyzer.sourceOrientation)

        if startPoint == nil {
            startPoint = rawPt
            startTime = currentPlayerTime
        } else if apexPoint == nil {
            apexPoint = rawPt
        } else if endPoint == nil {
            endPoint = rawPt
            endTime = currentPlayerTime
        }
    }

    private func togglePlayPause() {
        guard let player = player else { return }
        if isPlayingVideo {
            player.pause()
            isPlayingVideo = false
        } else {
            player.play()
            isPlayingVideo = true
        }
    }

    private func stepFrame(_ direction: Int) {
        guard let player else { return }
        player.pause()
        isPlayingVideo = false
        let step = Double(direction) / max(nominalFrameRate, 1)
        currentPlayerTime = min(max(0, currentPlayerTime + step), videoDuration)
        player.seek(
            to: CMTime(seconds: currentPlayerTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func clearPoints() {
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

    private func generateTrajectory() {
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
        saveProject()
    }

    private func prepareVideo(url: URL) async {
        isLoading = true
        defer { isLoading = false }
        
        await MainActor.run {
            player?.pause()
            clearPoints()
            player = nil
            analyzer.trajectories = []
        }

        let asset = AVURLAsset(url: url)
        do {
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
            let transform = try await track.load(.preferredTransform)
            let orientation = cgOrientation(from: transform)

            // Extract frame for preview and aspect ratio
            let duration = try await asset.load(.duration)
            // Use a frame 15% into the video. This avoids initial 'waggles' at 0.0s,
            // while ensuring the ball hasn't been hit yet (which often happens by 50%).
            let setupTime = CMTimeMultiplyByFloat64(duration, multiplier: 0.15)
            let still = try? await TrajectoryAnalyzer.extractFrame(from: url, at: setupTime)
            let loadedFrameRate = Double((try? await track.load(.nominalFrameRate)) ?? 30)
            
            await MainActor.run {
                clearPoints() // Must be called FIRST, otherwise it deletes the trajectory we just generated!
                
                analyzer.sourceOrientation = orientation
                analyzer.stillFrame = still
                analyzer.trajectories = [] // Default to empty so the Manual tools show up!
                
                videoDuration = CMTimeGetSeconds(duration)
                nominalFrameRate = loadedFrameRate > 0 ? loadedFrameRate : 30
                
                let newPlayer = AVPlayer(url: url)
                let interval = CMTime(value: 1, timescale: 30) // 30fps update rate
                playerObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak newPlayer] time in
                    guard let _ = newPlayer else { return }
                    if !self.isScrubbing {
                        self.currentPlayerTime = CMTimeGetSeconds(time)
                    }
                }
                
                playerNotificationToken = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: newPlayer.currentItem,
                    queue: .main
                ) { [weak newPlayer] _ in
                    newPlayer?.seek(to: .zero)
                    newPlayer?.pause()
                    self.isPlayingVideo = false
                }
                
                player = newPlayer
                isPlayingVideo = false
                preparedURL = url
            }
        } catch {
            print("Error preparing video: \(error)")
        }
    }

    private func runExport() {
        guard let url = videoURL, !analyzer.trajectories.isEmpty else { return }
        Task {
            await exporter.export(
                videoURL: url,
                trajectories: displayedTrajectories,
                orientation: analyzer.sourceOrientation,
                deceleration: deceleration,
                curveFactor: curveFactor,
                trailLength: trailLength
            )
        }
    }

    private func saveProject() {
        guard let videoURL, let startPoint, let apexPoint, let endPoint,
              let startTime, let endTime else { return }
        let project = TracerProject(
            videoFilename: videoURL.lastPathComponent,
            startPoint: StoredPoint(startPoint),
            apexPoint: StoredPoint(apexPoint),
            endPoint: StoredPoint(endPoint),
            startTime: startTime,
            endTime: endTime,
            apexTiming: deceleration,
            curve: curveFactor,
            trailLength: trailLength,
            mirrored: false
        )
        do { try TracerProjectStore.save(project) }
        catch { analyzer.errorMessage = "Could not save this editable trace: \(error.localizedDescription)" }
    }

    private func restoreProjectIfAvailable() async {
        guard videoURL == nil else { return }
        do {
            guard let (project, url) = try TracerProjectStore.load() else { return }
            await prepareVideo(url: url)
            videoURL = url
            startPoint = project.startPoint.cgPoint
            apexPoint = project.apexPoint.cgPoint
            endPoint = project.endPoint.cgPoint
            startTime = project.startTime
            endTime = project.endTime
            deceleration = project.apexTiming
            curveFactor = project.curve
            trailLength = project.trailLength
            isTrajectoryConfirmed = true
            generateTrajectory()
        } catch {
            analyzer.errorMessage = "Could not reopen the last editable trace: \(error.localizedDescription)"
        }
    }

    // MARK: – Geometry Transformation Helpers

    private func pointFromDisplay(_ location: CGPoint, in size: CGSize) -> CGPoint {
        let normalized = CGPoint(
            x: min(max(location.x / size.width, 0), 1),
            y: min(max(1 - location.y / size.height, 0), 1)
        )
        return denormalizeTapPoint(normalized, orientation: analyzer.sourceOrientation)
    }

    private func denormalizeTapPoint(_ tapPoint: CGPoint, orientation: CGImagePropertyOrientation) -> CGPoint {
        let rawX: CGFloat
        let rawY: CGFloat
        switch orientation {
        case .right:
            rawX = 1.0 - tapPoint.y
            rawY = tapPoint.x
        case .left:
            rawX = tapPoint.y
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

    private func uprightPoint(rawPoint: CGPoint, orientation: CGImagePropertyOrientation, in size: CGSize) -> CGPoint {
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

    private func placeholder<C: View>(@ViewBuilder content: () -> C) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.15))
            content()
        }
    }
}

private func cgOrientation(from transform: CGAffineTransform) -> CGImagePropertyOrientation {
    if transform.a == 0 && transform.b ==  1 && transform.c == -1 && transform.d == 0 { return .right }
    if transform.a == 0 && transform.b == -1 && transform.c ==  1 && transform.d == 0 { return .left  }
    if transform.a == -1 && transform.b == 0 && transform.c ==  0 && transform.d == -1 { return .down }
    return .up
}
