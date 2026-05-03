import ImageIO
import SwiftUI
import UIKit
import Vision

struct TrajectoryOverlayView: View {
    let stillFrame: UIImage
    let trajectories: [VNTrajectoryObservation]
    let orientation: CGImagePropertyOrientation

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
        let points = trajectory.projectedPoints.map { rawPoint in
            uprightPoint(rawX: rawPoint.x, rawY: rawPoint.y, size: size)
        }
        guard let first = points.first else { return }

        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        context.stroke(path, with: .color(color.opacity(0.4)), lineWidth: 10)
        context.stroke(path, with: .color(color), lineWidth: 3)

        for point in points {
            let dot = Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
            context.fill(dot, with: .color(color))
        }
    }

    // Vision returns coordinates in the raw pixel-buffer space (bottom-left origin).
    // The still frame is upright (preferred-transform applied), so rotate raw coords
    // to match, then flip Y for SwiftUI's top-left origin.
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
