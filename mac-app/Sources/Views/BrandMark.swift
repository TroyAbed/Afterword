import SwiftUI

/// The app mark: the tonspur, cut through at the moment you marked.
/// Drawn rather than shipped as an asset so it recolours with the colorway.
struct BrandMark: View {
    var size: CGFloat
    var palette: Palette
    /// false draws just the marks, without the app-icon tile
    var tile: Bool = true

    var body: some View {
        let s = size / 128
        let bar = tile ? palette.onInk : palette.ink
        ZStack(alignment: .topLeading) {
            if tile {
                RoundedRectangle(cornerRadius: 29 * s, style: .continuous)
                    .fill(palette.ink)
            }
            Rectangle().fill(bar)
                .frame(width: 56 * s, height: 24 * s).offset(x: 14 * s, y: 52 * s)
            Rectangle().fill(bar)
                .frame(width: 20 * s, height: 24 * s).offset(x: 94 * s, y: 52 * s)
            Rectangle().fill(palette.accent)
                .frame(width: 16 * s, height: 92 * s).offset(x: 74 * s, y: 18 * s)
        }
        .frame(width: size, height: size)
    }
}

/// Wordmark used in the sidebar header.
struct BrandLockup: View {
    @Environment(\.palette) private var palette
    var size: CGFloat = 17

    var body: some View {
        HStack(spacing: 9) {
            BrandMark(size: size * 1.5, palette: palette)
            Text("Afterword")
                .font(Brand.display(size))
                .tracking(-0.3)
                .foregroundStyle(palette.ink)
        }
    }
}
