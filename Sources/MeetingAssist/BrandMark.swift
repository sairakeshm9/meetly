import AppKit

/// Shared geometry keeps the menu glyph, app icon and thumbnails identical at every size.
enum BrandMark {
    static let green = NSColor(red: 23 / 255, green: 101 / 255, blue: 72 / 255, alpha: 1)

    static func draw(in rect: NSRect) {
        let side = min(rect.width, rect.height)
        let tile = rect.insetBy(dx: side * 0.05, dy: side * 0.05)
        green.setFill()
        NSBezierPath(roundedRect: tile, xRadius: side * 0.21, yRadius: side * 0.21).fill()
        drawLeaf(in: rect, color: .white)
    }

    static func drawLeaf(in rect: NSRect, color: NSColor) {
        let side = min(rect.width, rect.height)
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + side * x, y: rect.minY + side * y)
        }
        let mark = NSBezierPath()
        mark.move(to: point(0.23, 0.23))
        mark.curve(to: point(0.77, 0.77), controlPoint1: point(0.20, 0.65), controlPoint2: point(0.42, 0.83))
        mark.curve(to: point(0.23, 0.23), controlPoint1: point(0.83, 0.42), controlPoint2: point(0.65, 0.20))
        mark.close()
        mark.move(to: point(0.23, 0.23))
        mark.line(to: point(0.63, 0.63))
        mark.lineWidth = side * 0.06
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        color.setStroke()
        mark.stroke()
    }

    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
    }

    static func menuImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            drawLeaf(in: NSRect(x: -2, y: -2, width: 22, height: 22), color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }
}
