import SwiftUI
import UIKit
import Vision

struct TrajectoryOverlayView: View {
    let stillFrame: UIImage
    let trajectories: [VNTrajectoryObservation]

    var body: some View {
        Image(uiImage: stillFrame)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                Canvas { context, size in
                    for (index, trajectory) in trajectories.enumerated() {
                        let color = Self.colors[index % Self.colors.count]
                        drawTrajectory(trajectory, in: context, size: size, color: color)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private static let colors: [Color] = [.red, .yellow, .cyan, .green, .orange, .pink]

    private func drawTrajectory(
        _ trajectory: VNTrajectoryObservation,
        in context: GraphicsContext,
        size: CGSize,
        color: Color
    ) {
        let points = trajectory.projectedPoints.map { point in
            // Vision uses normalized coords with origin bottom-left;
            // SwiftUI Canvas uses origin top-left, so flip Y.
            CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
        }
        guard let first = points.first else { return }

        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }

        // Glow underneath
        context.stroke(path, with: .color(color.opacity(0.4)), lineWidth: 10)
        // Main line
        context.stroke(path, with: .color(color), lineWidth: 3)

        // Endpoint dots
        for point in points {
            let dot = Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
            context.fill(dot, with: .color(color))
        }
    }
}
