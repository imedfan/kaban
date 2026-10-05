// KabanUI sketch (SwiftUI, macOS only): draws the left-edge texture of a card from the kit v1 params.
// Not compiled here (the design box has no SwiftUI); geometry mirrors mascot-kit.js → textureSVG().
// Usage: card.overlay(alignment: .leading) { EdgeTextureView(texture: pick.texture).frame(width: 6) }
//        and clip the card with its RoundedRectangle so the strip follows the corners.
import SwiftUI

extension EdgeTexture {
    /// ink opacity: light = black on card, dark = white on card
    var opacity: (light: Double, dark: Double) {
        switch self {
        case .dots: (0.40, 0.42)
        case .stripes, .crosshatch, .solidThin: (0.30, 0.34)
        case .waves, .zigzag, .chevrons: (0.42, 0.46)
        case .grid: (0.32, 0.36)
        }
    }
}

struct EdgeTextureView: View {
    let texture: EdgeTexture
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, size in
            let w: CGFloat = 6, h = size.height
            let ink = Color(white: scheme == .dark ? 1 : 0)
            ctx.opacity = scheme == .dark ? texture.opacity.dark : texture.opacity.light
            ctx.clip(to: Path(CGRect(x: 0, y: 0, width: w, height: h)))
            var p = Path()
            func stroke(_ width: CGFloat, join: CGLineJoin = .miter) {
                ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: width, lineCap: .butt, lineJoin: join))
            }
            switch texture {
            case .dots:                                   // r 1, pitch 6, centres (1.5,1.5) (4.5,4.5)
                var y: CGFloat = 0
                while y < h + 6 {
                    p.addEllipse(in: CGRect(x: 0.5, y: y + 0.5, width: 2, height: 2))
                    p.addEllipse(in: CGRect(x: 3.5, y: y + 3.5, width: 2, height: 2))
                    y += 6
                }
                ctx.fill(p, with: .color(ink))
            case .stripes, .crosshatch:                   // 45°, spacing 4 ⟂ (vertical step 4·√2)
                let step: CGFloat = 4 * 2.0.squareRoot()
                var c: CGFloat = -w - step
                while c < h + w + step {
                    p.move(to: CGPoint(x: 0, y: c + w)); p.addLine(to: CGPoint(x: w, y: c))           // "/"
                    if texture == .crosshatch { p.move(to: CGPoint(x: 0, y: c)); p.addLine(to: CGPoint(x: w, y: c + w)) } // "\"
                    c += step
                }
                stroke(texture == .stripes ? 1.5 : 0.9)
            case .waves:                                  // x = 3 + 1.75·sin(2πy/8), stroke 1.4, round join
                var y: CGFloat = -1
                p.move(to: CGPoint(x: 3 + 1.75 * sin(2 * .pi * y / 8), y: y))
                while y <= h + 1 { y += 0.5; p.addLine(to: CGPoint(x: 3 + 1.75 * sin(2 * .pi * y / 8), y: y)) }
                stroke(1.4, join: .round)
            case .zigzag:                                 // x 1 ↔ 5, period 6, stroke 1.25
                var y: CGFloat = -3, i = 0
                p.move(to: CGPoint(x: 1, y: y))
                while y <= h + 3 { y += 3; i += 1; p.addLine(to: CGPoint(x: i % 2 == 1 ? 5 : 1, y: y)) }
                stroke(1.25)
            case .grid:                                   // pitch 3, offset 1.5, stroke 0.75
                for x in stride(from: CGFloat(1.5), to: w, by: 3) { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h)) }
                for y in stride(from: CGFloat(1.5), to: h, by: 3) { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
                stroke(0.75)
            case .chevrons:                               // "v" x 0.75…5.25, depth 2.25, period 4, stroke 1.25
                var y: CGFloat = -4
                while y < h + 4 {
                    p.move(to: CGPoint(x: 0.75, y: y)); p.addLine(to: CGPoint(x: 3, y: y + 2.25)); p.addLine(to: CGPoint(x: 5.25, y: y))
                    y += 4
                }
                stroke(1.25)
            case .solidThin:                              // bar 2 pt at the very edge
                ctx.fill(Path(CGRect(x: 0, y: 0, width: 2, height: h)), with: .color(ink))
            }
        }
        .accessibilityHidden(true)
    }
}
