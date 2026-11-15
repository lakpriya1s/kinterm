import SwiftUI

/// KinTerm's colors, from the "Name & logo" design.
enum KinTermBrand {
    static let blue = Color(red: 0x5c / 255, green: 0xa0 / 255, blue: 0xff / 255)
    static let ink = Color(red: 0x15 / 255, green: 0x16 / 255, blue: 0x1b / 255)
    static let term = Color(red: 0x8b / 255, green: 0x90 / 255, blue: 0x99 / 255)
    static let silver = Color(red: 0xc9 / 255, green: 0xcc / 255, blue: 0xd2 / 255)
}

/// The KinTerm mark: a glossy agent face. The brand face is silver with a
/// blue prompt for eyes; as a status light it takes the state's color and
/// expression.
struct KinTermMark: View {
    /// The face's color, or nil for the silver brand face.
    var front: Color?
    var expression: Expression = .prompt

    /// The face's expression: the logo's prompt, or an agent state's face
    /// from the Square faces set.
    enum Expression {
        case prompt, working, waiting, done, error
    }

    var body: some View {
        Canvas { context, size in
            Self.draw(in: &context, size: size, front: front, expression: expression)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("KinTerm")
    }

    /// Draws the mark into a square of `size`. Units are 1/120 of the side.
    /// `cornerRadius` is in those units; at 0 the face fills the square and
    /// leaves its edge to whatever masks it, like Icon Composer.
    static func draw(
        in context: inout GraphicsContext, size: CGSize, front: Color?, expression: Expression = .prompt,
        cornerRadius: CGFloat = 30
    ) {
        let side = min(size.width, size.height)
        let unit = side / 120
        let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: origin.x + x * unit, y: origin.y + y * unit, width: w * unit, height: h * unit)
        }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * unit, y: origin.y + y * unit)
        }
        let face = Path(roundedRect: rect(0, 0, 120, 120), cornerRadius: cornerRadius * unit, style: .continuous)

        // The body: lit from above, darker toward the bottom.
        let front = front ?? KinTermBrand.silver
        let base = NSColor(front)
        let stops: [Gradient.Stop] = [
            .init(color: Color(nsColor: base.blended(withFraction: 0.3, of: .white) ?? base), location: 0),
            .init(color: front, location: 0.55),
            .init(color: Color(nsColor: base.blended(withFraction: 0.2, of: .black) ?? base), location: 1),
        ]
        context.fill(face, with: .linearGradient(
            Gradient(stops: stops), startPoint: point(0, 0), endPoint: point(0, 120)))

        context.drawLayer { layer in
            layer.clip(to: face)

            // The gloss: a reflection over the top half, inset from a
            // rounded edge so the rim shows.
            if cornerRadius > 0 {
                layer.clip(to: Path(roundedRect: rect(2, 2, 116, 116), cornerRadius: (cornerRadius - 2) * unit,
                                    style: .continuous))
            }
            var gloss = Path()
            gloss.move(to: point(0, 0))
            gloss.addLine(to: point(120, 0))
            gloss.addLine(to: point(120, 38))
            gloss.addCurve(to: point(0, 40), control1: point(90, 54), control2: point(30, 54))
            gloss.closeSubpath()
            layer.fill(gloss, with: .linearGradient(
                Gradient(colors: [.white.opacity(0.5), .white.opacity(0)]),
                startPoint: point(0, 0), endPoint: point(0, 50)))
        }

        // A rim: bright along the top edge, shaded along the bottom.
        if cornerRadius > 0 {
            context.drawLayer { layer in
                layer.clip(to: face)
                layer.stroke(face, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0.9), location: 0),
                        .init(color: .white.opacity(0.15), location: 0.25),
                        .init(color: .black.opacity(0.05), location: 0.8),
                        .init(color: .black.opacity(0.35), location: 1),
                    ]), startPoint: point(0, 0), endPoint: point(0, 120)),
                    lineWidth: 4 * unit)
            }
        }

        // The features, pressed in: a light edge under each.
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .white.opacity(0.45), radius: 0.3 * unit, x: 0, y: 1.6 * unit))
            let ink = GraphicsContext.Shading.color(KinTermBrand.ink)
            guard expression == .prompt else {
                drawExpression(expression, in: &layer, origin: origin, scale: 3 * unit, ink: ink)
                return
            }
            // Laid out like the sleeping face (the idle state's, at three
            // times its size): eyes on one line, a small mouth below. The
            // left eye is the prompt, centered where that face's eye is.
            var chevron = Path()
            chevron.move(to: point(33.5, 47.25))
            chevron.addLine(to: point(47.5, 57.75))
            chevron.addLine(to: point(33.5, 68.25))
            layer.stroke(chevron, with: .color(KinTermBrand.blue),
                         style: StrokeStyle(lineWidth: 7.5 * unit, lineCap: .round, lineJoin: .round))
            layer.fill(Path(roundedRect: rect(69, 54, 21, 7.5), cornerRadius: 3.75 * unit), with: ink)
            layer.fill(Path(roundedRect: rect(51, 81, 18, 7.5), cornerRadius: 3.75 * unit), with: ink)
        }
    }

    /// A state's face from the Square faces set (`drawSquare`), still, on the
    /// mark. Units are its 40x40 grid: `origin` is the face's top left
    /// and `scale` the size of one unit.
    private static func drawExpression(
        _ expression: Expression, in context: inout GraphicsContext, origin: CGPoint, scale: CGFloat,
        ink: GraphicsContext.Shading
    ) {
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: origin.x + x * scale, y: origin.y + y * scale, width: w * scale, height: h * scale)
        }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        func pill(_ r: CGRect) -> Path {
            Path(roundedRect: r, cornerRadius: min(r.width, r.height) / 2)
        }
        let line = StrokeStyle(lineWidth: 2.5 * scale, lineCap: .round)

        switch expression {
        case .prompt:
            break

        case .working:
            // Pill eyes glancing to the side.
            context.fill(pill(rect(11.5, 13, 6, 10)), with: ink)
            context.fill(pill(rect(25.5, 13, 6, 10)), with: ink)
            context.fill(pill(rect(16.5, 27, 7, 2.5)), with: ink)

        case .waiting:
            // Surprised: tall eyes and an "o" mouth.
            context.fill(pill(rect(10, 11, 6, 11)), with: ink)
            context.fill(pill(rect(24, 11, 6, 11)), with: ink)
            context.stroke(Path(roundedRect: rect(17.25, 27.25, 5.5, 5.5), cornerRadius: 1.75 * scale),
                           with: ink, lineWidth: 2.5 * scale)

        case .done:
            // Happy: arched eyes and a smile.
            var eyes = Path()
            for center in [12.5, 27.5] {
                eyes.move(to: point(center - 3.25, 19))
                eyes.addArc(center: point(center, 18.5), radius: 3.25 * scale,
                            startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                eyes.addLine(to: point(center + 3.25, 19))
            }
            context.stroke(eyes, with: ink, style: line)
            var smile = Path()
            smile.addArc(center: point(20, 22), radius: 6.75 * scale,
                         startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            context.stroke(smile, with: ink, style: line)

        case .error:
            // X eyes and a frown.
            var eyes = Path()
            for center in [13.25, 27.25] {
                eyes.move(to: point(center - 3.2, 13.8))
                eyes.addLine(to: point(center + 3.2, 20.2))
                eyes.move(to: point(center + 3.2, 13.8))
                eyes.addLine(to: point(center - 3.2, 20.2))
            }
            context.stroke(eyes, with: ink, style: line)
            var frown = Path()
            frown.addArc(center: point(20, 33), radius: 4.75 * scale,
                         startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            context.stroke(frown, with: ink, style: line)
        }
    }
}

/// The app icon: the mark alone, with a shadow, inside the macOS icon grid
/// (an 824 tile in a 1024 canvas).
struct KinTermAppIcon: View {
    var front: Color?
    var expression: KinTermMark.Expression = .prompt

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            KinTermMark(front: front, expression: expression)
                .frame(width: side * 824 / 1024, height: side * 824 / 1024)
                .shadow(color: .black.opacity(0.35), radius: side * 0.02, y: side * 0.012)
                .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// The icon as an image, for the dock.
    @MainActor
    static func image(front: Color?, expression: KinTermMark.Expression = .prompt, side: CGFloat = 512) -> NSImage? {
        let renderer = ImageRenderer(
            content: KinTermAppIcon(front: front, expression: expression).frame(width: side, height: side))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
    }
}

/// The wordmark: "Kin" bright, "Term" muted, ending in a cursor.
struct KinTermWordmark: View {
    var size: CGFloat = 28

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: size * 0.06) {
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                Text("Kin").foregroundColor(.primary)
                Text("Term").foregroundColor(KinTermBrand.term)
            }
            .font(.system(size: size, weight: .heavy))
            .kerning(-size * 0.02)
            RoundedRectangle(cornerRadius: size * 0.04)
                .fill(KinTermBrand.blue)
                .frame(width: size * 0.42, height: size * 0.09)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("KinTerm")
    }
}
