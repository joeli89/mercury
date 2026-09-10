import SwiftUI

extension View {
    /// Applies Apple **Liquid Glass** (`glassEffect`) on macOS 26+, falling back
    /// to a frosted material on earlier systems so the app still builds and
    /// looks right against the 15.0 deployment target.
    @ViewBuilder
    func liquidGlass(in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThickMaterial, in: shape)
        }
    }
}
