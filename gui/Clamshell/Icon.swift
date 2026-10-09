import AppKit

// MARK: - Icon

/// A laptop, drawn rather than borrowed from SF Symbols so the two states can
/// differ in the one place that carries the meaning: the screen.
///
/// A lit (filled) screen means the machine keeps running with the lid shut; an
/// empty one means closing the lid will put it to sleep.
enum LaptopIcon {
    enum State {
        case awake, asleep, warning, armed
    }

    static func image(for state: State) -> NSImage {
        if state == .warning {
            let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                accessibilityDescription: "clamshell needs attention")
            image?.isTemplate = true
            return image ?? NSImage()
        }

        let size = NSSize(width: 18, height: 14)
        let lit = (state == .awake || state == .armed)

        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()

            // Screen: heavy bezel, either lit through or empty.
            let screen = NSBezierPath(
                roundedRect: NSRect(x: 2.7, y: 5.0, width: 12.6, height: 7.6),
                xRadius: 1.1, yRadius: 1.1
            )
            if lit {
                screen.fill()
            } else {
                screen.lineWidth = 1.4
                screen.stroke()
            }

            // Base, foreshortened: the deck tapering out to the front edge.
            let deck = NSBezierPath()
            deck.move(to: NSPoint(x: 2.9, y: 4.9))
            deck.line(to: NSPoint(x: 15.1, y: 4.9))
            deck.line(to: NSPoint(x: 17.0, y: 3.1))
            deck.line(to: NSPoint(x: 1.0, y: 3.1))
            deck.close()
            deck.fill()

            NSBezierPath(
                roundedRect: NSRect(x: 0.6, y: 2.0, width: 16.8, height: 1.6),
                xRadius: 0.8, yRadius: 0.8
            ).fill()

            if state == .armed {
                // Cut a gap first so the dot stays separate from the lit screen.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(
                    ovalIn: NSRect(x: 16.0 - 2.55, y: 12.0 - 2.55, width: 5.1, height: 5.1)
                ).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(
                    ovalIn: NSRect(x: 16.0 - 1.75, y: 12.0 - 1.75, width: 3.5, height: 3.5)
                ).fill()
            }

            return true
        }

        image.isTemplate = true
        return image
    }
}
