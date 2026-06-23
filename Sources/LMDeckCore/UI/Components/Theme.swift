import SwiftUI
import AppKit

// Shared view components used across the app (the Settings window is otherwise native SwiftUI —
// NavigationSplitView + Form(.grouped) — so it tracks the system look automatically). These three are
// reused by the menu-bar popup, the Models pane, and the About pane.

// The LMDeck "node" mark drawn as a crisp vector (coords from the app-icon design,
// 160-unit space — hexagon stroke 6, center dot r7, ink #111).
struct NodeMark: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 160
            func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            var hex = Path()
            hex.move(to: P(80, 34))
            hex.addLine(to: P(119.8, 57))
            hex.addLine(to: P(119.8, 103))
            hex.addLine(to: P(80, 126))
            hex.addLine(to: P(40.2, 103))
            hex.addLine(to: P(40.2, 57))
            hex.closeSubpath()
            let ink = Color(red: 0.067, green: 0.067, blue: 0.067)
            ctx.stroke(hex, with: .color(ink), style: StrokeStyle(lineWidth: 6 * s, lineJoin: .round))
            let r = 7 * s
            ctx.fill(Path(ellipseIn: CGRect(x: 80 * s - r, y: 80 * s - r, width: 2 * r, height: 2 * r)),
                     with: .color(ink))
        }
    }
}

// App-icon badge matching the design's <img>: white squircle (border-radius ≈ 0.2237·size,
// continuous) + node mark + 0.08 hairline + box-shadow 0 2px 8px rgba(0,0,0,.12).
struct AppIconBadge: View {
    var size: CGFloat = 76
    private var radius: CGFloat { size * 0.2237 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.white)
            NodeMark()
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: size * 0.08, x: 0, y: 2)
    }
}

// The Dock/app-icon artwork: the node mark on a soft grey squircle (instead of the white badge), with
// the standard ~10% icon margin. Rendered once to an NSImage and used only for the runtime Dock icon
// (NSApp.applicationIconImage) — the bundle/Finder icon and the menu-bar glyph are left as-is.
struct DockIconView: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let pad = s * 0.10
            let rect = s - pad * 2
            let radius = rect * 0.2237
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.84)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(.black.opacity(0.08), lineWidth: max(1, rect * 0.004))
                    )
                NodeMark()
            }
            .frame(width: rect, height: rect)
            .frame(width: s, height: s)
        }
    }
}

@MainActor
enum DockIcon {
    static let image: NSImage? = {
        let renderer = ImageRenderer(content: DockIconView().frame(width: 512, height: 512))
        renderer.scale = 2   // 1024px backing — crisp at any Dock size
        return renderer.nsImage
    }()
}

// A compact, fixed-height bordered text field whose text is reliably vertically centered. The native
// `.roundedBorder` style reserves asymmetric vertical space in a Form row (the box sits high, leaving
// a larger bottom margin), so the Server/Engines port & key fields use this instead. `width` sizes
// the box; height is fixed so the row matches the toggle rows above/below it.
extension View {
    func compactField(width: CGFloat) -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 7)
            .frame(width: width, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.6)
            )
    }
}

// 6pt rounded RAM usage bar: accent, then orange >70%, red >85%. Shared by the Models pane and the
// menu-bar at-a-glance panel.
struct RamBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(tone)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }

    private var tone: Color {
        if fraction > 0.85 { return Color(nsColor: .systemRed) }
        if fraction > 0.70 { return Color(nsColor: .systemOrange) }
        return Color(nsColor: .controlAccentColor)
    }
}

#if DEBUG
struct SharedComponents_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 24) {
            AppIconBadge(size: 76)
            RamBar(fraction: 0.62).frame(width: 240)
        }
        .padding(24)
    }
}
#endif
