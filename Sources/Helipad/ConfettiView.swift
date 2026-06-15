import SwiftUI

/// Falling-confetti overlay used when the Blocking tab drains to zero —
/// purely a celebration; not interactive, ignores hit-testing.
struct ConfettiView: View {
    /// How many pieces to fling. Reasonable on a 490×560 panel.
    static let pieceCount = 80

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

    /// Deterministic per-index so SwiftUI doesn't re-roll between renders.
    private var startX: CGFloat {
        let pct = Double((index * 31) % 100) / 100.0
        return CGFloat(pct) * screenSize.width
    }
    private var sway: CGFloat {
        let mod = ((index * 71) % 80) - 40
        return CGFloat(mod)
    }
    private var duration: Double {
        2.0 + Double((index * 17) % 18) / 10.0   // 2.0 … 3.8s
    }
    private var delay: Double {
        Double((index * 13) % 60) / 100.0        // up to 0.6s stagger
    }
    private var color: Color {
        let palette: [Color] = [
            .pink, .yellow, .green, .blue, .orange, .purple, .red, .mint, .cyan
        ]
        return palette[index % palette.count]
    }
    private var size: CGSize {
        let w = CGFloat(4 + (index * 11) % 5)
        let h = CGFloat(8 + (index * 7)  % 6)
        return .init(width: w, height: h)
    }
    private var spin: Double {
        Double(((index * 53) % 720) + 360)       // at least one full turn
    }

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: size.width, height: size.height)
            .rotationEffect(.degrees(animating ? spin : 0))
            .position(
                x: animating ? startX + sway : startX,
                y: animating ? screenSize.height + 40 : -40
            )
            .opacity(animating ? 0 : 1)
            .onAppear {
                withAnimation(.easeIn(duration: duration).delay(delay)) {
                    animating = true
                }
            }
    }
}
