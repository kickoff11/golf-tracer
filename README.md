# Golf Tracer

Golf Tracer is a manual iPhone and iPad editor that adds an animated golf-shot trajectory to an existing video. It does not attempt to detect the golf ball automatically.

## Workflow

1. Tap the video button and select a clip from Photos.
2. Use the timeline or previous/next-frame buttons to find the launch frame.
3. Tap the launch point, apex, and landing/direction point.
4. Generate the trajectory. Adjust apex timing, curve, and trail length as needed.
5. Use **Edit points** to drag any point without starting over.
6. Preview the animation and export it to Photos.

The last editable trace reopens automatically after the application is relaunched.

## Supported footage

- Portrait and landscape video
- Left- and right-moving shots
- Videos that are already mirrored or cropped
- Standard and slow-motion footage
- Variable source frame rates; frame stepping uses the source track's reported frame rate

Golf Tracer preserves the source orientation and aspect ratio. Exact output resolution depends on Apple's `HEVC 1920 × 1080` export preset and the source video.

## Architecture

- `ContentView.swift`: guided editor and playback controls
- `ManualTrajectoryEngine.swift`: deterministic three-point curve generation
- `TrajectoryRenderMath.swift`: shared preview/export timing and drawing calculations
- `AnimatedTrajectoryView.swift`: interactive preview
- `TrajectoryVideoExporter.swift`: renders and saves the finished video
- `TracerProject.swift`: durable video import and editable-project persistence
- `VideoPicker.swift`: Photos video selection

## Build and test

Open `GolfTracer.xcodeproj` in Xcode and run the `GolfTracer` scheme on an iOS 18.5 device or simulator.

Core tests can also run from Terminal:

```sh
swift test
```

The tests cover three-point curve geometry, orientation conversion, and the shared preview/export render calculation.

## Limitations

- Users must identify the trajectory points manually.
- One editable trace is retained at a time.
- Export requires permission to add media to Photos.
- The application does not calculate ball speed, distance, launch angle, or other launch-monitor measurements.
