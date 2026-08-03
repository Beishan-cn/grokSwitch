import AppKit
import SwiftUI

/// Menu bar Grok brand mark, drawn to match CodexBar's brand-icon mode
/// (`ProviderBrandIcon`: 16×16pt template SVG/PNG, no usage ring; percent is text).
enum MenuBarIcon {
    /// Fixed canvas so loading/non-loading never jumps in the menu bar.
    private static let canvasPointSize: CGFloat = 16
    private static let brandPointSize: CGFloat = 16
    private static let outputScale: CGFloat = 2

    private static let cacheLock = NSLock()
    private static var baseTemplate: NSImage?
    private static var renderedCache: [CacheKey: NSImage] = [:]

    private enum CacheKey: Hashable {
        case brand
        case loading
    }

    /// SwiftUI image for MenuBarExtra label.
    static func image(usage: ProfileUsage?) -> Image {
        Image(nsImage: nsImage(usage: usage))
    }

    static func nsImage(usage: ProfileUsage?) -> NSImage {
        // Match CodexBar brand+percent: clean brand mark; remaining % lives in the title text.
        // Only draw a ring for loading (partial arc) so the slot still feels alive while fetching.
        let key: CacheKey = usage?.status == .loading ? .loading : .brand

        cacheLock.lock()
        if let cached = renderedCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let image: NSImage
        if usage?.status == .loading {
            image = renderBrandWithLoadingArc()
        } else {
            image = renderBrandOnly()
        }

        cacheLock.lock()
        renderedCache[key] = image
        if renderedCache.count > 48 {
            renderedCache.removeAll(keepingCapacity: true)
            renderedCache[key] = image
        }
        cacheLock.unlock()
        return image
    }

    // MARK: - Brand (CodexBar-compatible)

    /// Load Grok mark like CodexBar `ProviderBrandIcon`: set size, mark template, no re-rasterize.
    private static func loadBaseTemplate() -> NSImage? {
        cacheLock.lock()
        if let baseTemplate {
            cacheLock.unlock()
            return baseTemplate
        }
        cacheLock.unlock()

        // Prefer PNG: AppKit's SVG rasterizer mishandles this evenodd path when redrawn.
        // SVG is still accepted the CodexBar way (size + isTemplate, never re-baked).
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "MenuBarGrok", withExtension: "png"),
            Bundle.main.url(forResource: "MenuBarGrok", withExtension: "svg"),
            URL(fileURLWithPath: "Resources/MenuBarGrok.png"),
            URL(fileURLWithPath: "Resources/MenuBarGrok.svg"),
        ]

        var loaded: NSImage?
        for case let url? in candidates {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let img = NSImage(contentsOf: url) else { continue }
            // Critical: match CodexBar — assign point size on the original rep, do not redraw.
            img.size = NSSize(width: brandPointSize, height: brandPointSize)
            img.isTemplate = true
            loaded = img
            break
        }

        cacheLock.lock()
        baseTemplate = loaded
        cacheLock.unlock()
        return loaded
    }

    // MARK: - Rendered bitmaps (never return shared baseTemplate)

    private static func renderBrandOnly() -> NSImage {
        let size = NSSize(width: canvasPointSize, height: canvasPointSize)
        return renderIntoBitmap(size: size) { rect in
            let markSize = brandPointSize * 0.92
            let markRect = NSRect(
                x: rect.midX - markSize / 2,
                y: rect.midY - markSize / 2,
                width: markSize,
                height: markSize
            )
            if let base = loadBaseTemplate() {
                base.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            } else {
                drawMonogram(in: markRect)
            }
        }
    }

    /// Brand mark + faint incomplete track while usage is loading (same 16pt canvas).
    private static func renderBrandWithLoadingArc() -> NSImage {
        let size = NSSize(width: canvasPointSize, height: canvasPointSize)
        return renderIntoBitmap(size: size) { rect in
            drawLoadingComposite(in: rect)
        }
    }

    private static func renderIntoBitmap(size: NSSize, draw: (NSRect) -> Void) -> NSImage {
        let pixels = Int(size.width * outputScale)
        let image = NSImage(size: size)
        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) {
            rep.size = size
            image.addRepresentation(rep)
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                draw(NSRect(origin: .zero, size: size))
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            image.lockFocus()
            draw(NSRect(origin: .zero, size: size))
            image.unlockFocus()
        }
        image.isTemplate = true
        return image
    }

    private static func drawLoadingComposite(in rect: NSRect) {
        let markSize = brandPointSize * 0.78
        let markRect = NSRect(
            x: rect.midX - markSize / 2,
            y: rect.midY - markSize / 2,
            width: markSize,
            height: markSize
        )

        if let base = loadBaseTemplate() {
            base.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 0.9)
        } else {
            drawMonogram(in: markRect)
        }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 1.0
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 40, endAngle: 300)
        track.lineWidth = 1.25
        track.lineCapStyle = .round
        NSColor.black.withAlphaComponent(0.35).setStroke()
        track.stroke()
    }

    private static func drawMonogram(in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let fontSize = min(rect.width, rect.height) * 0.72
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]
        let text = "G" as NSString
        let textSize = text.size(withAttributes: attrs)
        let origin = CGPoint(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2
        )
        text.draw(at: origin, withAttributes: attrs)
    }

    #if DEBUG
    static func resetCacheForTesting() {
        cacheLock.lock()
        baseTemplate = nil
        renderedCache.removeAll()
        cacheLock.unlock()
    }
    #endif
}
