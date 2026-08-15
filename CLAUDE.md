# Golf Tracer project instructions

Golf Tracer is a manual trajectory-overlay editor for iPhone and iPad. Do not add automatic ball detection, confidence scores, generated fallback paths, or filming restrictions intended to make detection work.

The supported workflow is:

1. Import a video.
2. Scrub or step to the launch frame and place the launch point.
3. Place the apex and landing/direction points.
4. Generate and adjust the curve, apex timing, and trail length.
5. Preview the result and export it to Photos.

The preview and exporter must use `TrajectoryRenderMath` so timing and appearance remain identical. Coordinate conversion and curve behavior require deterministic tests. Imported videos and the current trace are stored by `TracerProjectStore` so editing can resume after relaunch.

Use plain language when reporting changes to Vincent. The project builds with Xcode 16.4 and targets iOS 18.5. Do not permanently delete user artifacts when a recoverable archive is practical.
