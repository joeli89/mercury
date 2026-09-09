import SwiftUI
import CoreImage

/// A background the screen recording is composited onto (Screen Studio-style).
struct BackgroundOption: Identifiable, Hashable {
    enum Style: Hashable {
        case none
        case solid(String)              // hex
        case gradient(String, String)   // top-left hex, bottom-right hex
        case image(URL)
    }

    let id: String
    let name: String
    let style: Style

    var isNone: Bool { if case .none = style { return true }; return false }

    /// Built-in presets shown in the picker.
    static let presets: [BackgroundOption] = {
        let none = BackgroundOption(id: "none", name: "None", style: .none)
        let tapestries: [(id: String, name: String, file: String)] = [
            ("tapestry_01", "UK & Europe",       "Wise_Tapestry_01_UK_Europe_Orange_Blue_Lg"),
            ("tapestry_02", "Australasia",        "Wise_Tapestry_02_Australasia_SAsia_Aqua_Purple_Lg"),
            ("tapestry_03", "Americas & E. Asia", "Wise_Tapestry_03_NAmerica_EAsia_Pink_Orange_Lg"),
            ("tapestry_04", "Europe & SE Asia",   "Wise_Tapestry_04_Europe_SEAsia_Blue_Yellow_Lg"),
            ("tapestry_05", "N. Europe & Africa", "Wise_Tapestry_05_NEurope_WAfrica_Dark_Green_Lg"),
            ("tapestry_06", "The Americas",       "Wise_Tapestry_06_NAmerica_SAmerica_Red_Blue_Lg"),
            ("tapestry_07", "Pacific",            "Wise_Tapestry_07_NAmerica_EAsia_Green_Blue_Yellow_Lg"),
            ("tapestry_08", "Africa & Europe",    "Wise_Tapestry_08_NAfrica_Europe_Green_Yellow_Orange_Lg"),
            ("tapestry_09", "Latin America",      "Wise_Tapestry_09_C+SAmerica_Europe_Pink_Yellow_Lg"),
            ("tapestry_10", "Middle East",        "Wise_Tapestry_10_MiddleEast_Australasia_Pink_Blue_Lg"),
            ("tapestry_full", "Wise World",       "Wise_Tapestry_Platform_Full_Lg_v2"),
        ]
        let imageOptions = tapestries.compactMap { t -> BackgroundOption? in
            guard let url = Bundle.main.url(forResource: t.file, withExtension: "jpg") else { return nil }
            return BackgroundOption(id: t.id, name: t.name, style: .image(url))
        }
        return [none] + imageOptions
    }()

    /// A custom background from a user-picked image file.
    static func custom(_ url: URL) -> BackgroundOption {
        .init(id: "custom", name: "Custom", style: .image(url))
    }
}

/// Amount of empty space around the inset screen content.
enum BackgroundPadding: String, CaseIterable, Identifiable {
    case small = "S", medium = "M", large = "L"
    var id: String { rawValue }
    var fraction: CGFloat {
        switch self {
        case .small: return 0.035
        case .medium: return 0.07
        case .large: return 0.12
        }
    }
}

// MARK: - Color helpers

extension CIColor {
    static func fromHex(_ hex: String) -> CIColor {
        let (r, g, b) = rgb(from: hex)
        return CIColor(red: r, green: g, blue: b)
    }
}

extension Color {
    init(hex: String) {
        let (r, g, b) = rgb(from: hex)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

private func rgb(from hex: String) -> (CGFloat, CGFloat, CGFloat) {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    var v: UInt64 = 0
    Scanner(string: s).scanHexInt64(&v)
    let r = CGFloat((v >> 16) & 0xFF) / 255
    let g = CGFloat((v >> 8) & 0xFF) / 255
    let b = CGFloat(v & 0xFF) / 255
    return (r, g, b)
}

// MARK: - SwiftUI swatch preview

extension BackgroundOption {
    @ViewBuilder
    var swatch: some View {
        switch style {
        case .none:
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "slash.circle").foregroundStyle(.secondary)
            }
        case .solid(let hex):
            Rectangle().fill(Color(hex: hex))
        case .gradient(let a, let b):
            LinearGradient(colors: [Color(hex: a), Color(hex: b)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .image(let url):
            AsyncImageOrColor(url: url)
        }
    }
}

/// Lightweight file-image thumbnail (AsyncImage doesn't load file URLs on macOS reliably).
/// GeometryReader gives the image an explicit frame so aspectFill doesn't bleed
/// outside the cell bounds.
private struct AsyncImageOrColor: View {
    let url: URL
    var body: some View {
        if let img = NSImage(contentsOf: url) {
            GeometryReader { geo in
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        } else {
            Rectangle().fill(.quaternary)
        }
    }
}
