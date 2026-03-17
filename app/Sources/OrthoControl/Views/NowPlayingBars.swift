import SwiftUI

/// Animated equalizer bars indicating active playback.
struct NowPlayingBars: View {
    let isPlaying: Bool

    @State private var animating = false

    private let barCount = 3
    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 1
    private let maxHeight: CGFloat = 10
    private let minFraction: CGFloat = 0.2

    // Each bar gets a different height pattern and speed
    private let phases: [(lo: CGFloat, hi: CGFloat, duration: Double)] = [
        (0.2, 0.9, 0.45),
        (0.3, 1.0, 0.35),
        (0.15, 0.75, 0.5),
    ]

    var body: some View {
        HStack(alignment: .bottom, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { i in
                let phase = phases[i]
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(.primary)
                    .frame(width: barWidth, height: barHeight(for: phase))
                    .animation(
                        isPlaying
                            ? .easeInOut(duration: phase.duration)
                                .repeatForever(autoreverses: true)
                            : .default,
                        value: animating
                    )
            }
        }
        .frame(width: CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing, height: maxHeight)
        .onAppear {
            if isPlaying { animating = true }
        }
        .onChange(of: isPlaying) { _, playing in
            animating = playing
        }
    }

    private func barHeight(for phase: (lo: CGFloat, hi: CGFloat, duration: Double)) -> CGFloat {
        if isPlaying {
            return maxHeight * (animating ? phase.hi : phase.lo)
        } else {
            return maxHeight * minFraction
        }
    }
}
