import AppKit
import SwiftUI

/// Menu bar Grok brand mark, drawn to match CodexBar's brand-icon mode
/// (`ProviderBrandIcon`: 16×16pt template SVG/PNG, no usage ring; percent is text).
enum MenuBarIcon {
    /// CodexBar `ProviderBrandIcon` uses 16×16.
    private static let brandPointSize: CGFloat = 16
    /// Slightly larger canvas when we attach a remaining ring so the stroke doesn't clip.
    private static let ringPointSize: CGFloat = 18
    private static let outputScale: CGFloat = 2

    private static let cacheLock = NSLock()
    private static var baseTemplate: NSImage?
    private static var renderedCache: [CacheKey: NSImage] = [:]

    private struct CacheKey: Hashable {
        /// -3 = brand only (no ring); -2 loading arc; -1 idle; 0…20 remaining 5% buckets
        var remainingBucket: Int
        var severity: Int
    }

    /// SwiftUI image for MenuBarExtra label.
    static func image(usage: ProfileUsage?) -> Image {
        Image(nsImage: nsImage(usage: usage))
    }

    static func nsImage(usage: ProfileUsage?) -> NSImage {
        // Match CodexBar brand+percent: clean brand mark; remaining % lives in the title text.
        // Only draw a ring for loading (partial arc) so the slot still feels alive while fetching.
        let key: CacheKey
        if usage?.status == .loading {
            key = CacheKey(remainingBucket: -2, severity: 0)
        } else {
            key = CacheKey(remainingBucket: -3, severity: 0)
        }

        cacheLock.lock()
        if let cached = renderedCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let image: NSImage
        if usage?.status == .loading {
            image = renderBrandWithLoadingArc()
        } else if let brand = loadBaseTemplate() {
            image = brand
        } else {
            image = renderFallbackMonogram()
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

    // MARK: - Loading arc (only non-brand decoration)

    /// Brand mark + faint incomplete track while usage is loading (CodexBar animates bars; we keep it minimal).
    private static func renderBrandWithLoadingArc() -> NSImage {
        let size = NSSize(width: ringPointSize, height: ringPointSize)
        let pixels = Int(ringPointSize * outputScale)
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
                drawLoadingComposite(in: NSRect(origin: .zero, size: size))
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            image.lockFocus()
            drawLoadingComposite(in: NSRect(origin: .zero, size: size))
            image.unlockFocus()
        }

        image.isTemplate = true
        return image
    }

    private static func drawLoadingComposite(in rect: NSRect) {
        let markSize = brandPointSize
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
        let radius = min(rect.width, rect.height) / 2 - 1.25
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 40, endAngle: 300)
        track.lineWidth = 1.5
        track.lineCapStyle = .round
        NSColor.black.withAlphaComponent(0.35).setStroke()
        track.stroke()
    }

    private static func renderFallbackMonogram() -> NSImage {
        let size = NSSize(width: brandPointSize, height: brandPointSize)
        let image = NSImage(size: size, flipped: false) { rect in
            drawMonogram(in: rect)
            return true
        }
        image.isTemplate = true
        return image
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
