import SwiftUI

/// Diagonal confetti overlay used when the Blocking tab drains to zero —
/// pieces shoot upward from both bottom corners and fade as they cross the
/// panel. Purely a celebration; not interactive, ignores hit-testing.
struct ConfettiView: View {
    /// How many pieces to fling. Half launch from each corner.
    static let pieceCount = 100

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<Self.pieceCount, id: \.self) { i in
                    ConfettiPiece(index: i, screenSize: geo.size)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ConfettiPiece: View {
    let index: Int
    let screenSize: CGSize

    @State private var animating = false

    /// Alternating left/right corner so each side gets ~half the pieces.
    private var startsLeft: Bool { index % 2 == 0 }

    /// Start ~at the corner, with a tiny per-piece offset so they don't all
    /// emit from a single pixel.
    private var startPosition: CGPoint {
        let xOffset = CGFloat((index * 7) % 28)
        let yOffset = CGFloat((index * 11) % 16)
        return .init(
            x: startsLeft ? xOffset : screenSize.width - xOffset,
            y: screenSize.height - yOffset
        )
    }

    /// Flight angle in [35°, 80°] from horizontal — keeps the spray diagonal
    /// rather than straight up or sideways.
    private var angleDegrees: Double {
        35.0 + Double((index * 7) % 46)
    }

    /// End point is well off-screen along the chosen angle so pieces clear
    /// the panel before fading completes.
    private var endPosition: CGPoint {
        let theta = angleDegrees * .pi / 180.0
        let distance = max(screenSize.width, screenSize.height) * 1.4
            * (1.0 + CGFloat((index * 11) % 30) / 100.0)
        let dx = CGFloat(cos(theta)) * distance
        let dy = CGFloat(sin(theta)) * distance
        let signX: CGFloat = startsLeft ? 1 : -1
        return .init(
            x: startPosition.x + signX * dx,
            y: startPosition.y - dy
        )
    }

    /// 1.6 … 3.2 s; easeOut so the burst feels like an initial launch.
    private var duration: Double {
        1.6 + Double((index * 17) % 16) / 10.0
    }

    /// Slight stagger so pieces don't all leave at once.
    private var delay: Double {
        Double((index * 13) % 40) / 100.0
    }

    private var color: Color {
        let palette: [Color] = [
            .pink, .yellow, .green, .blue, .orange, .purple, .red, .mint, .cyan
        ]
        return palette[index % palette.count]
    }

    private var size: CGSize {
        .init(
            width:  CGFloat(4 + (index * 11) % 5),
            height: CGFloat(8 + (index * 7)  % 6)
        )
    }

    /// At least one full turn so the rectangles spin visibly mid-flight.
    private var spin: Double {
        Double(((index * 53) % 720) + 360)
    }

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: size.width, height: size.height)
            .rotationEffect(.degrees(animating ? spin : 0))
            .position(animating ? endPosition : startPosition)
            .opacity(animating ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: duration).delay(delay)) {
                    animating = true
                }
            }
    }
}
