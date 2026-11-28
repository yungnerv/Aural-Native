import SwiftUI

/// A stationary charcoal field behind scrolling content and system glass.
private struct MusicBackground: View {
    var body: some View {
        EllipticalGradient(
            colors: [Color(.sRGB, white: 0.11, opacity: 1),
                     Color(.sRGB, white: 0.071, opacity: 1)],
            center: UnitPoint(x: 0.5, y: 0.32),
            startRadiusFraction: 0.1,
            endRadiusFraction: 0.75
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    func musicBackground() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background { MusicBackground() }
    }
}
