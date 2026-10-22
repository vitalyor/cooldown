import AppKit
import SwiftUI

enum Theme {
    static let cobalt = dynamic(light: (0.22, 0.36, 0.95), dark: (0.53, 0.62, 1.00))
    static let coral = dynamic(light: (0.84, 0.41, 0.26), dark: (0.98, 0.58, 0.42))
    static let mint = dynamic(light: (0.05, 0.56, 0.45), dark: (0.33, 0.83, 0.68))
    static let amber = dynamic(light: (0.80, 0.55, 0.04), dark: (0.98, 0.76, 0.26))
    static let signal = dynamic(light: (0.83, 0.22, 0.24), dark: (1.00, 0.44, 0.44))

    static func tint(for provider: ProviderID) -> Color {
        switch provider {
        case .codex: return cobalt
        case .claude: return coral
        }
    }

    /// Calm while there is room, warmer as the limit runs low.
    static func level(remaining: Double, tint: Color) -> Color {
        if remaining <= 10 { return signal }
        if remaining <= 25 { return amber }
        return tint
    }

    static func number(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }

    /// A quiet surface for grouped content inside the glass window.
    static let well = Color.primary.opacity(0.055)

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

/// One line in the menu bar item: an agent's remaining limit, marked with the agent's sign.
enum MenuMark: Equatable {
    case prompt     // ›_ , a terminal prompt, for Codex
    case asterisk   // ✻ , for Claude
}

struct MenuLine: Equatable {
    enum Activity: Equatable { case idle, working, waiting }

    var remaining: Double?
    var color: NSColor
    /// A small sign drawn in the agent's colour before the number.
    var mark: MenuMark
    var glyph: NSImage? = nil
    /// An agent session is writing (a soft light runs along its line) or
    /// waits for the person (a small amber point by the sign).
    var activity: Activity = .idle
}

/// The menu bar item: a line per agent, stacked, each emptying as its limit is spent.
/// The agent is told apart by its coloured sign; the number stays in the menu bar's own colour
/// so it is readable on any wallpaper; the line itself shows how much is left.
enum GaugeIcon {
    /// Agent colours, lighter on a dark menu bar and deeper on a light one, so they never sink in.
    static let claude = adaptive(light: (0.76, 0.37, 0.24), dark: (0.96, 0.62, 0.48))
    static let codex = adaptive(light: (0.25, 0.36, 0.92), dark: (0.66, 0.73, 1.00))
    static let codexMark = MenuMark.prompt
    static let claudeMark = MenuMark.asterisk

    /// The menu bar glyphs the installed apps ship for themselves (template images), used as they are
    /// and only tinted; when an app is missing, the simple drawn sign stands in.
    static let codexGlyph = shippedGlyph(bundleIDs: ["com.openai.codex", "com.openai.chat"], resource: "chatgptTemplate")
    static let claudeGlyph = shippedGlyph(bundleIDs: ["com.anthropic.claudefordesktop"], resource: "TrayIconTemplate")

    private static func shippedGlyph(bundleIDs: [String], resource: String) -> NSImage? {
        for id in bundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
                  let image = Bundle(url: url)?.image(forResource: resource) else { continue }
            return image
        }
        return nil
    }

    private static func tinted(_ image: NSImage, _ color: NSColor, in rect: NSRect, alpha: CGFloat = 1) {
        let copy = NSImage(size: rect.size, flipped: false) { bounds in
            image.draw(in: bounds)
            color.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        copy.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
    }

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }

    // MARK: Level colour

    /// Green while there is plenty, then a smooth turn through yellow and orange to red.
    /// Stops are mixed in OKLab (no muddy midpoints) with smoothstep inside each stretch,
    /// so the colour barely moves near the top and changes most around the middle.
    private static let stops: [(Double, (Double, Double, Double))] = [
        (0, (0.94, 0.27, 0.27)),    // red
        (12, (0.96, 0.33, 0.24)),
        (30, (0.98, 0.58, 0.16)),   // orange
        (50, (0.96, 0.80, 0.18)),   // yellow
        (72, (0.45, 0.82, 0.36)),   // fresh green
        (100, (0.30, 0.80, 0.42)),  // green
    ]

    static func levelColor(_ remaining: Double) -> NSColor {
        let value = min(100, max(0, remaining))
        var lower = stops[0], upper = stops[stops.count - 1]
        for (a, b) in zip(stops, stops.dropFirst()) where value >= a.0 && value <= b.0 {
            lower = a; upper = b; break
        }
        let span = upper.0 - lower.0
        var t = span > 0 ? (value - lower.0) / span : 0
        t = t * t * (3 - 2 * t)
        let a = oklab(lower.1), b = oklab(upper.1)
        let mixed = (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
        let rgb = srgb(mixed)
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }

    private static func oklab(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = lin(c.0), g = lin(c.1), b = lin(c.2)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private static func srgb(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
        let l = pow(c.0 + 0.3963377774 * c.1 + 0.2158037573 * c.2, 3)
        let m = pow(c.0 - 0.1055613458 * c.1 - 0.0638541728 * c.2, 3)
        let s = pow(c.0 - 0.0894841775 * c.1 - 1.2914855480 * c.2, 3)
        func gamma(_ v: Double) -> Double {
            let x = min(1, max(0, v))
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return (gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    // MARK: Drawing

    /// Vector marks, centred on the row like the digits and the line.
    private static func drawMark(_ mark: MenuMark, color: NSColor, x: CGFloat, center: CGFloat, size: CGFloat, width: CGFloat) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = max(1.2, size * 0.2)
        let half = size / 2
        switch mark {
        case .prompt:
            path.move(to: NSPoint(x: x + 0.5, y: center + half))
            path.line(to: NSPoint(x: x + size * 0.5, y: center))
            path.line(to: NSPoint(x: x + 0.5, y: center - half))
            path.move(to: NSPoint(x: x + size * 0.85, y: center - half))
            path.line(to: NSPoint(x: x + width - 0.5, y: center - half))
        case .asterisk:
            let cx = x + width / 2
            for step in 0..<4 {
                let angle = Double(step) * .pi / 4 + .pi / 2
                let dx = CGFloat(cos(angle)) * half, dy = CGFloat(sin(angle)) * half
                path.move(to: NSPoint(x: cx - dx, y: center - dy))
                path.line(to: NSPoint(x: cx + dx, y: center + dy))
            }
        }
        path.stroke()
    }

    /// Where each line's bar sits inside the picture (bottom-left origin), for the light that
    /// runs along a working agent's line: an animated layer over the button, drawn by the system
    /// compositor, so the picture itself never has to be redrawn for it.
    static func barFrames(lines: [MenuLine], attention: Bool, showText: Bool) -> (size: NSSize, bars: [NSRect]) {
        let single = lines.count == 1
        let height: CGFloat = 18
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: single ? 12 : 9, weight: .semibold)
        let numbers = lines.map { line in line.remaining.map { "\(Int($0.rounded()))%" } ?? "—" }
        func width(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: numberFont]).width) }
        let markSize = numberFont.capHeight
        let glyphSize: CGFloat = single ? 15 : 9.5
        let usesGlyphs = lines.contains { $0.glyph != nil }
        let markWidth = usesGlyphs ? max(glyphSize, ceil(markSize * 1.45)) : ceil(markSize * 1.45)
        let numberWidth = showText ? (numbers.map(width).max() ?? 0) : 0
        let dotWidth: CGFloat = attention ? 8 : 0
        let barWidth: CGFloat = 24
        let thickness: CGFloat = single ? 5 : 3
        let rowGap: CGFloat = single ? 0 : 8.5
        let total = dotWidth + markWidth + 3 + (showText ? numberWidth + 4 : 0) + barWidth
        let bars = lines.indices.map { index -> NSRect in
            let center = single ? height / 2 : height / 2 + (index == 0 ? rowGap / 2 : -rowGap / 2)
            return NSRect(x: total - barWidth, y: center - thickness / 2, width: barWidth, height: thickness)
        }
        return (NSSize(width: total, height: height), bars)
    }

    /// `still`: motion is reduced, so working is shown by a small point instead of moving light.
    static func image(lines: [MenuLine], attention: Bool, showText: Bool, still: Bool = false) -> NSImage {
        let single = lines.count == 1
        let height: CGFloat = 18
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: single ? 12 : 9, weight: .semibold)
        let numbers = lines.map { line in line.remaining.map { "\(Int($0.rounded()))%" } ?? "—" }
        func width(_ text: String, _ font: NSFont) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        let markSize = numberFont.capHeight      // marks are as tall as the digits
        let glyphSize: CGFloat = single ? 15 : 9.5
        let usesGlyphs = lines.contains { $0.glyph != nil }
        let markWidth = usesGlyphs ? max(glyphSize, ceil(markSize * 1.45)) : ceil(markSize * 1.45)
        let numberWidth = showText ? (numbers.map { width($0, numberFont) }.max() ?? 0) : 0
        let dotWidth: CGFloat = attention ? 8 : 0
        let barWidth: CGFloat = 24
        let thickness: CGFloat = single ? 5 : 3
        let rowGap: CGFloat = single ? 0 : 8.5   // distance between the two row centres
        let total = dotWidth + markWidth + 3 + (showText ? numberWidth + 4 : 0) + barWidth

        let image = NSImage(size: NSSize(width: total, height: height), flipped: false) { _ in
            if attention {
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(x: 0, y: height / 2 - 2.75, width: 5.5, height: 5.5)).fill()
            }
            let barX = total - barWidth
            for (index, line) in lines.enumerated() {
                // Row centres are symmetric around the middle; text and line share the same centre.
                let center = single ? height / 2 : height / 2 + (index == 0 ? rowGap / 2 : -rowGap / 2)

                func drawCentered(_ text: String, font: NSFont, color: NSColor, right: CGFloat) {
                    let string = text as NSString
                    let size = string.size(withAttributes: [.font: font])
                    // Put the middle of the capitals (not of the line box) on the row centre.
                    let originY = center - font.capHeight / 2 + font.descender
                    string.draw(at: NSPoint(x: right - size.width, y: originY),
                                withAttributes: [.font: font, .foregroundColor: color])
                }

                let signAlpha: CGFloat = 1
                let signColor = line.color
                if let glyph = line.glyph {
                    // Claude's tray glyph has more empty margin than OpenAI's; even them out.
                    let side = glyphSize * (line.mark == .asterisk ? 1.3 : 1)
                    tinted(glyph, line.color, in: NSRect(x: dotWidth + (markWidth - side) / 2, y: center - side / 2,
                                                         width: side, height: side), alpha: signAlpha)
                } else {
                    drawMark(line.mark, color: signColor, x: dotWidth, center: center, size: markSize, width: markWidth)
                }
                // A small point by the sign: amber when the agent waits for the person; in the
                // agent's colour when it works and motion is reduced.
                if line.activity == .waiting || (line.activity == .working && still) {
                    let point: CGFloat = single ? 4 : 3
                    (line.activity == .waiting ? NSColor.systemOrange : line.color).setFill()
                    NSBezierPath(ovalIn: NSRect(x: dotWidth + markWidth - point * 0.6, y: center + (single ? 3 : 1.6),
                                                width: point, height: point)).fill()
                }
                if showText {
                    drawCentered(numbers[index], font: numberFont, color: .labelColor,
                                 right: dotWidth + markWidth + 3 + numberWidth)
                }

                let track = NSRect(x: barX, y: center - thickness / 2, width: barWidth, height: thickness)
                NSColor.labelColor.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: track, xRadius: thickness / 2, yRadius: thickness / 2).fill()
                if let remaining = line.remaining, remaining > 0.5 {
                    var fill = track
                    fill.size.width = max(thickness, barWidth * CGFloat(min(100, remaining) / 100))
                    levelColor(remaining).setFill()
                    NSBezierPath(roundedRect: fill, xRadius: thickness / 2, yRadius: thickness / 2).fill()
                }

            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: Shared pieces

struct Note: View {
    let symbol: String
    let text: String
    var color: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

/// A grouped block of content: a soft well with generous corners, as in System Settings.
struct Well<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.well))
    }
}

/// A round glass button for the header, Liquid Glass style. While work is going on it dims
/// instead of turning.
struct GlassIconButton: View {
    let symbol: String
    var help: String = ""
    var spinning = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .opacity(spinning ? 0.4 : 1)
                .animation(.easeInOut(duration: 0.25), value: spinning)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help)
    }
}

/// A segmented choice on a glass track, with a selection that slides between options.
struct GlassSegments<Value: Hashable, Label: View>: View {
    let options: [Value]
    @Binding var selection: Value
    var tint: (Value) -> Color = { _ in .accentColor }
    @ViewBuilder var label: (Value, Bool) -> Label
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { selection = option }
                } label: {
                    label(option, selected)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 6)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(tint(option).opacity(0.22))
                                    .overlay(Capsule().strokeBorder(tint(option).opacity(0.35), lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
    }
}

struct BackBar: View {
    let title: String
    let back: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            GlassIconButton(symbol: "chevron.left", help: L("Назад"), action: back)
            Text(title).font(.system(size: 17, weight: .semibold))
            Spacer()
        }
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }
}
