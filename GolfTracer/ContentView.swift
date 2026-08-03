import AVKit
import PhotosUI
import SwiftUI

struct ContentView: View {
    @StateObject private var vm = GolfTracerViewModel()
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 4) {
                mainArea
                    .frame(maxHeight: .infinity)

                if let error = vm.analyzer.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                controlsArea
                
                if case .failed(let msg) = vm.exporter.status {
                    Text("Export failed: \(msg)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal)
            .navigationTitle("Golf Tracer")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $vm.showPicker) {
                VideoPicker(videoURL: $vm.videoURL, errorMessage: $vm.analyzer.errorMessage)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        if vm.hasResult {
                            if vm.exporter.status == .exporting {
                                ProgressView()
                            } else {
                                Button(action: vm.runExport) { Image(systemName: "square.and.arrow.down") }
                            }
                        }
                        Button { vm.showPicker = true } label: { Image(systemName: "video.badge.plus") }
                    }
                }
                if vm.hasResult {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Reset") {
                            vm.reset()
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .overlay {
            if vm.showPreFlightGuide && vm.videoURL == nil {
                preFlightGuide
            }
        }
    }
    
    private var preFlightGuide: some View {
        ZStack {
            Color.black.opacity(0.8).ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 60))
                    .foregroundStyle(.white)
                Text("Pre-Flight Checklist")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 16) {
                    Label("Use a tripod for perfectly stable footage.", systemImage: "checkmark.circle.fill")
                    Label("Place the camera directly down the target line.", systemImage: "checkmark.circle.fill")
                    Label("Shoot at 60fps or higher if possible.", systemImage: "checkmark.circle.fill")
                }
                .foregroundStyle(.gray)
                .font(.body)
                
                Button {
                    withAnimation {
                        vm.showPreFlightGuide = false
                    }
                } label: {
                    Text("Got it")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 14)
                        .background(Color.white)
                        .clipShape(Capsule())
                }
                .padding(.top, 10)
            }
            .padding(32)
            .background(Color(.systemGray6).opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(radius: 20)
        }
    }

    // MARK: – Main area

    @ViewBuilder
    private var mainArea: some View {
        if !vm.analyzer.trajectories.isEmpty, let url = vm.videoURL {
            let aspect = vm.analyzer.stillFrame.map { $0.size.width / $0.size.height } ?? 9.0 / 16.0
            VStack(alignment: .leading, spacing: 8) {
                AnimatedTrajectoryView(
                    videoURL: url,
                    trajectories: vm.displayedTrajectories,
                    orientation: vm.analyzer.sourceOrientation,
                    aspectRatio: aspect,
                    deceleration: vm.deceleration,
                    curveFactor: vm.curveFactor,
                    tracerTheme: vm.tracerTheme,
                    tracerThickness: vm.tracerThickness,
                    tracerTailLength: vm.tracerTailLength
                )
                .id(url.path + (vm.analyzer.bestTrajectory?.id.uuidString ?? ""))
                .scaleEffect(vm.viewScale)
                .offset(vm.viewOffset)
                .gesture(
                    DragGesture()
                        .onChanged { val in
                            if vm.viewScale > 1.0 {
                                let proposed = CGSize(
                                    width: vm.lastViewOffset.width + val.translation.width,
                                    height: vm.lastViewOffset.height + val.translation.height
                                )
                                vm.viewOffset = vm.constrainOffset(proposed, scale: vm.viewScale)
                            }
                        }
                        .onEnded { val in
                            if vm.viewScale > 1.0 {
                                vm.lastViewOffset = vm.viewOffset
                            }
                        }
                )
                .gesture(
                    MagnificationGesture()
                        .onChanged { val in 
                            vm.viewScale = max(1.0, vm.lastViewScale * val) 
                            vm.viewOffset = vm.constrainOffset(vm.lastViewOffset, scale: vm.viewScale)
                        }
                        .onEnded { val in 
                            vm.lastViewScale = vm.viewScale 
                            vm.lastViewOffset = vm.viewOffset
                        }
                )
                .clipped()
            }
        } else if vm.videoURL != nil {
            VStack(spacing: 8) {
                ZStack {
                    if let player = vm.player {
                        PlayerLayerView(player: player)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        GeometryReader { geo in
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    vm.handleTap(at: location, in: geo.size)
                                }

                            if let start = vm.startPoint {
                                let visualStart = vm.uprightPoint(rawPoint: start, in: geo.size)
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 6, height: 6)
                                    .overlay(Circle().stroke(Color.white, lineWidth: 1))
                                    .position(visualStart)
                                    .shadow(radius: 2)
                            }
                            
                            if let apex = vm.apexPoint {
                                let visualApex = vm.uprightPoint(rawPoint: apex, in: geo.size)
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 6, height: 6)
                                    .overlay(Circle().stroke(Color.white, lineWidth: 1))
                                    .position(visualApex)
                                    .shadow(radius: 2)
                            }
                            
                            if let setup = vm.analyzer.setupInfo {
                                if let personBox = setup.personBoundingBox {
                                    Rectangle()
                                        .stroke(Color.blue, lineWidth: 2)
                                        .frame(width: personBox.width * geo.size.width, height: personBox.height * geo.size.height)
                                        .position(x: personBox.midX * geo.size.width, y: (1 - personBox.midY) * geo.size.height)
                                }
                                if let clubBox = setup.clubHeadRegion {
                                    Rectangle()
                                        .stroke(Color.yellow, lineWidth: 2)
                                        .frame(width: clubBox.width * geo.size.width, height: clubBox.height * geo.size.height)
                                        .position(x: clubBox.midX * geo.size.width, y: (1 - clubBox.midY) * geo.size.height)
                                }
                                if let shaftLine = setup.clubShaftLine {
                                    Path { path in
                                        let start = CGPoint(x: shaftLine.start.x * geo.size.width, y: (1 - shaftLine.start.y) * geo.size.height)
                                        let end = CGPoint(x: shaftLine.end.x * geo.size.width, y: (1 - shaftLine.end.y) * geo.size.height)
                                        path.move(to: start)
                                        path.addLine(to: end)
                                    }
                                    .stroke(Color.yellow, lineWidth: 2)
                                }
                                if let ballPos = setup.estimatedBallPosition {
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 10, height: 10)
                                        .position(x: ballPos.x * geo.size.width, y: (1 - ballPos.y) * geo.size.height)
                                }
                            }

                            if let end = vm.endPoint {
                                let visualEnd = vm.uprightPoint(rawPoint: end, in: geo.size)
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 6, height: 6)
                                    .overlay(Circle().stroke(Color.white, lineWidth: 1))
                                    .position(visualEnd)
                                    .shadow(radius: 2)
                            }
                        }
                    } else {
                        ProgressView("Preparing video…")
                    }
                }
                .aspectRatio(vm.analyzer.stillFrame.map { $0.size.width / $0.size.height } ?? 16/9, contentMode: .fit)
                .scaleEffect(vm.viewScale)
                .offset(vm.viewOffset)
                .gesture(
                    DragGesture()
                        .onChanged { val in
                            if vm.viewScale > 1.0 {
                                let proposed = CGSize(
                                    width: vm.lastViewOffset.width + val.translation.width,
                                    height: vm.lastViewOffset.height + val.translation.height
                                )
                                vm.viewOffset = vm.constrainOffset(proposed, scale: vm.viewScale)
                            }
                        }
                        .onEnded { val in
                            if vm.viewScale > 1.0 {
                                vm.lastViewOffset = vm.viewOffset
                            }
                        }
                )
                .gesture(
                    MagnificationGesture()
                        .onChanged { val in 
                            vm.viewScale = max(1.0, vm.lastViewScale * val)
                            vm.viewOffset = vm.constrainOffset(vm.lastViewOffset, scale: vm.viewScale)
                        }
                        .onEnded { val in 
                            vm.lastViewScale = vm.viewScale
                            vm.lastViewOffset = vm.viewOffset
                        }
                )
                .clipped()
                
                if let player = vm.player {
                    HStack(spacing: 12) {
                        Button(action: vm.togglePlayPause) {
                            Image(systemName: vm.isPlayingVideo ? "pause.fill" : "play.fill")
                                .font(.title3)
                                .padding(8)
                                .background(Color.accentColor.opacity(0.1))
                                .clipShape(Circle())
                        }
                        
                        Slider(value: $vm.currentPlayerTime, in: 0...max(vm.videoDuration, 0.1)) { editing in
                            vm.isScrubbing = editing
                            if !editing {
                                player.seek(to: CMTime(seconds: vm.currentPlayerTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                            }
                        }
                        .onChange(of: vm.currentPlayerTime) { _, newValue in
                            if vm.isScrubbing {
                                player.seek(to: CMTime(seconds: newValue, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                            }
                        }
                        
                        Text(String(format: "%.2f / %.2fs", vm.currentPlayerTime, vm.videoDuration))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }
            }
        } else if vm.isLoading {
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
        if vm.videoURL != nil {
            VStack(spacing: 8) {
                instructionsView
                if vm.isTrajectoryConfirmed {
                    sliderArea
                    Divider().padding(.vertical, 8)
                    customizationHUD
                }
            }
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var instructionsView: some View {
        HStack {
            switch vm.currentState {
            case .idle: 
                EmptyView()
            case .tappingStart:
                Text("Tap the Tee (Start)")
            case .tappingApex:
                Text("Tap the Apex (Highest)")
                Spacer()
                Button("Undo") { vm.startPoint = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .tappingEnd:
                Text("Tap the Landing (End)")
                Spacer()
                Button("Undo") { vm.apexPoint = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .confirming:
                Text("Confirm Points?")
                Spacer()
                Button("Undo") { vm.endPoint = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Generate") {
                    vm.confirmTrajectory()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .tweaking:
                Text("Trajectory Ready.")
                Spacer()
                Button("Reset") {
                    vm.reset()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .font(.subheadline.bold())
        .padding(.horizontal)
    }

    private var customizationHUD: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                // Theme Picker
                VStack(alignment: .leading) {
                    Text("Theme").font(.caption).foregroundStyle(.secondary)
                    Picker("Theme", selection: $vm.tracerTheme) {
                        ForEach(TracerTheme.allCases) { theme in
                            Text(theme.rawValue).tag(theme)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.white)
                    .onChange(of: vm.tracerTheme) { _, _ in vm.generateTrajectory() }
                }
                
                // Thickness Slider
                VStack(alignment: .leading) {
                    Text("Thickness").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $vm.tracerThickness, in: 2.0...12.0)
                        .frame(width: 100)
                        .onChange(of: vm.tracerThickness) { _, _ in vm.generateTrajectory() }
                }
                
                // Tail Length Slider
                VStack(alignment: .leading) {
                    Text("Tail Length").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $vm.tracerTailLength, in: 0.1...1.0)
                        .frame(width: 100)
                        .onChange(of: vm.tracerTailLength) { _, _ in vm.generateTrajectory() }
                }
            }
            .padding(.horizontal)
        }
    }

    private var sliderArea: some View {
        VStack(spacing: -8) {
            HStack {
                Text("Apex %:")
                    .font(.subheadline.bold())
                    .frame(width: 70, alignment: .leading)
                
                Button {
                    vm.deceleration = max(0.10, vm.deceleration - 0.01)
                    vm.generateTrajectory()
                } label: { 
                    Image(systemName: "minus.square.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                Slider(value: $vm.deceleration, in: 0.10...0.80)
                    .onChange(of: vm.deceleration) { _, _ in
                        vm.generateTrajectory()
                    }
                
                Button {
                    vm.deceleration = min(0.80, vm.deceleration + 0.01)
                    vm.generateTrajectory()
                } label: { 
                    Image(systemName: "plus.square.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                Text(String(format: "%.2f", vm.deceleration))
                    .monospacedDigit()
                    .font(.subheadline)
                    .frame(width: 45, alignment: .trailing)
            }
            
            HStack {
                Text("Curve:")
                    .font(.subheadline.bold())
                    .frame(width: 70, alignment: .leading)
                
                Button {
                    vm.curveFactor = max(0.70, vm.curveFactor - 0.01)
                    vm.generateTrajectory()
                } label: { 
                    Image(systemName: "minus.square.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                Slider(value: $vm.curveFactor, in: 0.70...1.30)
                    .onChange(of: vm.curveFactor) { _, _ in
                        vm.generateTrajectory()
                    }
                
                Button {
                    vm.curveFactor = min(1.30, vm.curveFactor + 0.01)
                    vm.generateTrajectory()
                } label: { 
                    Image(systemName: "plus.square.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                Text(String(format: "%.2f", vm.curveFactor))
                    .monospacedDigit()
                    .font(.subheadline)
                    .frame(width: 45, alignment: .trailing)
            }
        }
        .padding(.horizontal)
    }

    private func placeholder<C: View>(@ViewBuilder content: () -> C) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.15))
            content()
        }
    }
}
