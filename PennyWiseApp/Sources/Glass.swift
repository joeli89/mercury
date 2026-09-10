import SwiftUI

extension View {
    /// Applies Apple **Liquid Glass** (`glassEffect`) on macOS 26+, falling back
    /// to a frosted material on earlier systems so the app still builds and
    /// looks right against the 15.0 deployment target.
    ///
    /// A dark tint is applied so these controls stay a legible *dark* surface
    /// regardless of what's behind them — untinted Liquid Glass turns light on
    /// a white background, which washes out our white icons/text.
    @ViewBuilder
    func liquidGlass(in shape: some Shape, tint: Color = .black.opacity(0.5)) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint), in: shape)
        } else {
            self.background(.ultraThickMaterial, in: shape)
                 .background(tint, in: shape)
        }
    }
}
