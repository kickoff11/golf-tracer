# GolfTracer Project Instructions

## About the user
Vincent is not a software developer by background. Do not assume familiarity with programming concepts, terminal commands, file structures, or technical jargon. When explaining what a change does or why something works, use plain language that a non-coder can follow. Analogies and real-world comparisons are welcome.

## Communication style
- Do not use short forms or abbreviations. Write out full words. For example, write "function" not "func", write "variable" not "var", write "configuration" not "config", write "repository" not "repo".
- Do not use unexplained jargon. If a technical term must be used, briefly explain what it means in parentheses the first time it appears in a response.
- Keep explanations concise but complete. One clear sentence is better than a vague paragraph.

## Decision making
- For actions that are reversible — editing a file, building the project, running the simulator, reading code — just proceed immediately without stopping to ask for confirmation.
- Only pause and ask before actions that cannot be undone or that affect things outside this project, such as pushing code to GitHub, deleting files permanently, or spending money.

## Project overview
This is a personal iOS application called Golf Tracer, built with Swift and SwiftUI. The purpose of the app is to automatically detect a golf ball's trajectory in a video and overlay an animated yellow arc on top of the footage.

### Technology stack
- **SwiftUI** — the framework used to build the user interface (the screens and buttons the user sees)
- **AVFoundation** — Apple's framework for reading, playing, and writing video files
- **Custom detection (no machine-learning framework)** — the app finds the ball with its own mathematics rather than Apple's Vision framework. It compares each video frame to the one before it to spot what moved, then fits a gravity-shaped curve through those movements. This is described in detail in the "How the auto-detection works" section below.
- **Photos** — Apple's framework for saving the finished video to the iPhone's photo library

### Repository
- GitHub username: kickoff11
- Repository: github.com/kickoff11/golf-tracer
- Local project path: /Users/vincent/Documents/GolfTracer

### Device and build environment
- Mac: Intel iMac running macOS 15.7.5
- Xcode version: 16.4 (installed via the xcodes command-line tool through Homebrew)
- iOS simulator runtime: iOS 18.5
- Distribution method: free Apple ID sideload over USB (no paid Apple Developer Program); the sideload certificate expires every 7 days and must be renewed by re-running from Xcode

## Key source files
- `ContentView.swift` — the main screen of the app; handles video picking, triggering analysis, and showing results
- `TrajectoryAnalyzer.swift` — the coordinator: it runs the detector over the video, hands the results to the curve fitter, keeps the arc only if it scores highly enough, and extracts a still frame for preview
- `StaticCameraBallDetector.swift` — finds candidate ball positions by comparing each frame to the previous one (frame differencing) and keeping the bright, white, moving spots
- `BallTrajectory.swift` — the finished trajectory data, plus `TrajectoryFitter`, the mathematics that fits one smooth gravity-shaped arc through the candidate positions and rejects the false ones
- `AnimatedTrajectoryView.swift` — displays the video with the yellow trajectory arc animated on top in real time
- `TrajectoryVideoExporter.swift` — renders the video with the trajectory drawn on every frame and saves the result to the Photos library
- `TrajectoryOverlayView.swift` — shows a still image with the trajectory arc drawn on it (used for preview)
- `Movie.swift` — a small helper that handles transferring a video file from the Photos picker into the app

## How the auto-detection works
The method assumes the camera never moves (it is on a fixed tripod). That single assumption is what makes the ball easy to find.

1. The user picks a video from their iPhone's photo library.
2. The app reads every frame of the video using `AVAssetReader` (a tool that steps through a video frame by frame).
3. Each frame is compared to the frame just before it. Because the camera is locked in place, the background is identical in both frames and cancels out, leaving only the things that actually moved. This step is called frame differencing.
4. Among the moving spots, the app keeps only the ones that are bright and colourless — that is, white, like a golf ball. This produces a short list of "the ball might be here" guesses for every frame. The list deliberately includes some wrong guesses (the club head, a shiny shoe, a fluttering leaf); sorting those out is the next step's job.
5. All the guesses from the whole video are handed to the curve fitter. A ball in flight obeys gravity, so its sideways position drifts at a steady rate (a straight line over time) and its height rises then falls (a parabola over time). The fitter uses a standard technique called RANSAC (Random Sample Consensus — it repeatedly guesses a curve from a tiny random handful of points and keeps whichever guess the most other points agree with) to find the one gravity-shaped arc that the most guesses fall on, and ignores the rest as false detections.
6. The winning arc is given a confidence score from 0 to 1. If it scores below the acceptance threshold, it is thrown away and the app reports that no ball was found, rather than drawing a wrong arc.
7. An accepted arc is sampled into many closely-spaced points and displayed as an animated yellow line that draws itself across the video as it plays.

## Detection parameters and why they matter
All of these are first estimates. They are the knobs to turn once a real 60-frames-per-second clip filmed down the line is available to test against.

In `StaticCameraBallDetector.swift`:
- `motionThreshold` (set to 16, on a 0 to 255 brightness scale) is how much a spot's brightness must change between two frames to count as "moving". Lower catches fainter motion but lets in more background noise.
- `scoreThreshold` (set to 0.03) is the minimum combined "moving and white" score for a spot to be treated as a possible ball.
- `candidatesPerFrame` (set to 6) is how many ball guesses to keep from each frame. The curve fitter discards the wrong ones, so it is safe to keep a few.

In `BallTrajectory.swift` (the `TrajectoryFitter`):
- `inlierTolerance` (set to 0.03, meaning 3 percent of the frame size) is how close a guess must sit to a candidate curve to count as agreeing with it.
- `extrapolateFraction` (set to 0.25) is how far past the last trusted detection the arc is allowed to continue toward the landing spot, as a fraction of the observed flight time. Kept small because guessing the exact landing from only the early flight is unreliable.

In `TrajectoryAnalyzer.swift`:
- `minAcceptConfidence` (set to 0.30) is the lowest confidence score an arc may have and still be drawn. Below this the fit is judged to be scattered noise rather than a real ball flight, and nothing is shown.

## Filming recommendations for best detection results
- **Use a tripod and do not move the camera.** This is the single most important rule. The whole detection method relies on the background staying perfectly still between frames so the moving ball stands out by comparison. Filming handheld will break it.
- **Stand directly behind the golfer, looking down the target line** (the direction the ball is meant to travel). This "down the line" view is the standard angle in the shot-tracer videos this app is meant to imitate, and it keeps the ball in frame for longer as it flies away and climbs.
- Film at 60 frames per second or higher. In the iPhone Settings application, go to Camera → Record Video and select 4K at 60fps or 1080p at 60fps. A higher frame rate means the ball appears in more frames, giving the curve fitter more points to work with.
- Keep the camera roughly at waist to chest height, pointing slightly upward toward where the ball will fly.
- A plain, steady background (open sky, fairway) helps the white ball stand out. Avoid busy movement behind the golfer, such as people walking or trees thrashing in wind, because anything else that moves becomes a false guess the fitter then has to reject.

> Note: this reverses the earlier guidance, which recommended filming from the side and warned against standing behind the golfer. That advice applied to the old Vision-based detection, which has been removed. The current static-camera method is built specifically for the down-the-line tripod setup.
