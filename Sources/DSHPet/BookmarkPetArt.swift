import SwiftUI

/// Original vector mascot. Geometry is expressed in a fixed 80 × 96 artboard.
struct BookmarkPetArt: View {
    var phase: TimeInterval
    var mood: String
    var lean: Double

    var body: some View {
        Canvas { context, bounds in
            let scale = min(bounds.width / 80, bounds.height / 96)
            context.translateBy(x: (bounds.width - 80 * scale) / 2, y: (bounds.height - 96 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            let ink = Color(red: 0.12, green: 0.24, blue: 0.25)
            let cover = Color(red: 0.25, green: 0.52, blue: 0.49)
            let paper = Color(red: 1.00, green: 0.95, blue: 0.80)
            let ribbon = Color(red: 0.92, green: 0.49, blue: 0.31)
            let sleepy = ["disconnected", "unreachable", "stopped"].contains(mood)
            let thinking = ["waiting", "jumping"].contains(mood)
            let bob = sin(phase * (thinking ? 4.0 : 1.9))
            context.fill(Path(ellipseIn: CGRect(x: 14, y: 86, width: 52, height: 5)), with: .color(.black.opacity(0.13)))
            context.translateBy(x: 40, y: 76 + bob * (sleepy ? 0.4 : 1.6))
            context.rotate(by: .degrees(-6 + lean * 11 + (mood == "wave" ? 8 * sin(phase * 8) : 0)))
            context.translateBy(x: -40, y: -76)
            func shape(_ path: Path, _ color: Color, border: CGFloat = 2.2) {
                context.fill(path, with: .color(color))
                context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: border, lineJoin: .round))
            }
            var feet = Path()
            feet.move(to: CGPoint(x: 31, y: 73)); feet.addQuadCurve(to: CGPoint(x: 23, y: 83), control: CGPoint(x: 36, y: 82))
            feet.move(to: CGPoint(x: 48, y: 74)); feet.addQuadCurve(to: CGPoint(x: 55, y: 83), control: CGPoint(x: 46, y: 84))
            context.stroke(feet, with: .color(ink), style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
            shape(Path(roundedRect: CGRect(x: 12, y: 17, width: 54, height: 60), cornerRadius: 7), cover)
            shape(Path(roundedRect: CGRect(x: 17, y: 13, width: 49, height: 59), cornerRadius: 5), paper)
            var tab = Path()
            tab.move(to: CGPoint(x: 45, y: 13)); tab.addLine(to: CGPoint(x: 45, y: 32))
            tab.addLine(to: CGPoint(x: 51, y: 28)); tab.addLine(to: CGPoint(x: 57, y: 32))
            tab.addLine(to: CGPoint(x: 57, y: 13)); tab.closeSubpath()
            shape(tab, ribbon, border: 1.6)
            let blink = phase.truncatingRemainder(dividingBy: 4.2) > 3.98 || sleepy
            for x in [28.0, 44.0] {
                let eye = CGRect(x: x + lean, y: 43, width: 5.0, height: blink ? 1.8 : 6.5)
                context.fill(Path(roundedRect: eye, cornerRadius: 2.2), with: .color(ink))
            }
            var mouth = Path()
            mouth.move(to: CGPoint(x: 34, y: 55))
            let pleased = mood == "done" || mood == "wave"
            mouth.addQuadCurve(to: CGPoint(x: 43, y: 55),
                               control: CGPoint(x: 38, y: mood == "failed" ? 51 : (pleased ? 62 : 58)))
            context.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
        .accessibilityLabel("书签桌宠")
    }
}
