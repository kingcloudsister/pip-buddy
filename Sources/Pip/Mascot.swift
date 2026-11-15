import SwiftUI

/// Pip's face from the mockup: a white rounded square in ink with a little antenna.
/// Eyes closed when nothing runs, watching while apps work, smiling when something finished.
struct Mascot: View {
    let mood: Mood
    let excited: Bool   // a "ready" card is showing: hop

    /// Redraws are the main CPU cost of an always-on strip, so only moving faces redraw often.
    private var interval: Double {
        if excited { return 1.0 / 30 }
        switch mood {
        case .busy: return 1.0 / 10
        case .happy, .sleepy: return 2
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                g.scaleBy(x: size.width / 40, y: size.width / 40)
                draw(&g, t)
            }
        }
    }

    private func draw(_ g: inout GraphicsContext, _ t: Double) {
        let hop = excited ? -abs(sin(t * 6)) * 3 : 0
        g.translateBy(x: 0, y: hop)
        let ink = GraphicsContext.Shading.color(Theme.ink)
        let pen = StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round)

        // Antenna: still when calm, waves while thinking.
        let sway = mood == .busy ? sin(t * 5) * 1.6 : 0
        var antenna = Path()
        antenna.move(to: CGPoint(x: 29.5, y: 7))
        antenna.addLine(to: CGPoint(x: 32.5 + sway, y: 2.6))
        g.stroke(antenna, with: ink, style: pen)

        let box = Path(roundedRect: CGRect(x: 3.5, y: 7, width: 32, height: 31), cornerRadius: 10, style: .continuous)
        g.fill(box, with: .color(.white))
        g.stroke(box, with: ink, style: pen)

        let eyes = [CGPoint(x: 13.5, y: 20), CGPoint(x: 25.5, y: 20)]
        switch mood {
        case .sleepy:
            // The mockup's "-ᴗ-".
            for e in eyes {
                var p = Path()
                p.move(to: CGPoint(x: e.x - 2.3, y: e.y))
                p.addLine(to: CGPoint(x: e.x + 2.3, y: e.y))
                g.stroke(p, with: ink, style: pen)
            }
            smile(&g, width: 4, depth: 2.6, pen: pen)

        case .busy:
            let blink = t.truncatingRemainder(dividingBy: 3.7) < 0.14
            let look = sin(t * 2) * 1.3
            for e in eyes {
                if blink {
                    var p = Path()
                    p.move(to: CGPoint(x: e.x - 1.8, y: e.y))
                    p.addLine(to: CGPoint(x: e.x + 1.8, y: e.y))
                    g.stroke(p, with: ink, style: pen)
                } else {
                    g.fill(Path(ellipseIn: CGRect(x: e.x - 1.7 + look, y: e.y - 2, width: 3.4, height: 4)), with: ink)
                }
            }
            var m = Path()
            m.move(to: CGPoint(x: 17.8, y: 26.5))
            m.addLine(to: CGPoint(x: 21.2, y: 26.5))
            g.stroke(m, with: ink, style: pen)

        case .happy:
            for e in eyes {
                var p = Path()
                p.move(to: CGPoint(x: e.x - 2.4, y: e.y + 1))
                p.addQuadCurve(to: CGPoint(x: e.x + 2.4, y: e.y + 1), control: CGPoint(x: e.x, y: e.y - 2.6))
                g.stroke(p, with: ink, style: pen)
            }
            var m = Path()
            m.move(to: CGPoint(x: 16.3, y: 25))
            m.addQuadCurve(to: CGPoint(x: 22.7, y: 25), control: CGPoint(x: 19.5, y: 31))
            m.closeSubpath()
            g.fill(m, with: ink)
        }
    }

    private func smile(_ g: inout GraphicsContext, width: CGFloat, depth: CGFloat, pen: StrokeStyle) {
        var m = Path()
        m.move(to: CGPoint(x: 19.5 - width / 2, y: 25.5))
        m.addQuadCurve(to: CGPoint(x: 19.5 + width / 2, y: 25.5), control: CGPoint(x: 19.5, y: 25.5 + depth))
        g.stroke(m, with: .color(Theme.ink), style: pen)
    }
}
