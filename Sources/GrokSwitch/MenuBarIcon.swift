import AppKit
import SwiftUI

/// Menu bar Grok brand mark + optional remaining-usage ring.
/// Brand path matches CodexBar's `ProviderIcon-grok.svg`.
enum MenuBarIcon {
    private static let pointSize: CGFloat = 18
    private static let cacheLock = NSLock()
    private static var baseTemplate: NSImage?
    private static var renderedCache: [CacheKey: NSImage] = [:]

    private struct CacheKey: Hashable {
        var remainingBucket: Int // 0…20 (5% steps), or -1 unknown, -2 loading
        var severity: Int
    }

    /// SwiftUI image for MenuBarExtra label.
    static func image(usage: ProfileUsage?) -> Image {
        Image(nsImage: nsImage(usage: usage))
    }

    static func nsImage(usage: ProfileUsage?) -> NSImage {
        let key: CacheKey
        if usage?.status == .loading {
            key = CacheKey(remainingBucket: -2, severity: 0)
        } else if let remaining = usage?.remainingPercent, usage?.status == .ready {
            let bucket = Int((remaining / 5.0).rounded()) // 0…20
            let severity: Int = switch usage?.severity {
            case .ok: 1
            case .warning: 2
            case .critical: 3
            default: 0
            }
            key = CacheKey(remainingBucket: bucket, severity: severity)
        } else {
            key = CacheKey(remainingBucket: -1, severity: 0)
        }

        cacheLock.lock()
        if let cached = renderedCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let image = render(
            remainingPercent: usage?.status == .ready ? usage?.remainingPercent : nil,
            loading: usage?.status == .loading
        )

        cacheLock.lock()
        renderedCache[key] = image
        // Bound cache growth.
        if renderedCache.count > 48 {
            renderedCache.removeAll(keepingCapacity: true)
            renderedCache[key] = image
        }
        cacheLock.unlock()
        return image
    }

    // MARK: - Render

    private static func render(remainingPercent: Double?, loading: Bool) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: false) { rect in
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.saveGState()

            // Leave a 1pt margin so the ring doesn't clip in the status bar.
            let inset: CGFloat = 1
            let markRect = rect.insetBy(dx: inset + 1.5, dy: inset + 1.5)

            if let base = loadBaseTemplate() {
                // Template: draw with black; system recolors via isTemplate.
                base.draw(
                    in: markRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: remainingPercent == nil && !loading ? 0.95 : 1.0
                )
            } else {
                // Fallback monogram if asset missing.
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .bold),
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

            // Usage ring: remaining % as arc around the mark.
            if let remaining = remainingPercent {
                let ringRect = rect.insetBy(dx: inset, dy: inset)
                let center = CGPoint(x: ringRect.midX, y: ringRect.midY)
                let radius = min(ringRect.width, ringRect.height) / 2 - 0.5
                let track = NSBezierPath()
                track.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: 0,
                    endAngle: 360
                )
                track.lineWidth = 1.5
                NSColor.black.withAlphaComponent(0.22).setStroke()
                track.stroke()

                let clamped = max(0, min(100, remaining)) / 100
                if clamped > 0.001 {
                    let fill = NSBezierPath()
                    // Start at top, sweep clockwise for remaining.
                    let start: CGFloat = 90
                    let end = start - CGFloat(clamped * 360)
                    fill.appendArc(
                        withCenter: center,
                        radius: radius,
                        startAngle: start,
                        endAngle: end,
                        clockwise: true
                    )
                    fill.lineWidth = 1.75
                    fill.lineCapStyle = .round
                    NSColor.black.withAlphaComponent(0.95).setStroke()
                    fill.stroke()
                }
            } else if loading {
                // Subtle dashed track while loading.
                let ringRect = rect.insetBy(dx: inset, dy: inset)
                let center = CGPoint(x: ringRect.midX, y: ringRect.midY)
                let radius = min(ringRect.width, ringRect.height) / 2 - 0.5
                let track = NSBezierPath()
                track.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: 40,
                    endAngle: 300
                )
                track.lineWidth = 1.5
                track.lineCapStyle = .round
                NSColor.black.withAlphaComponent(0.35).setStroke()
                track.stroke()
            }

            ctx?.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func loadBaseTemplate() -> NSImage? {
        cacheLock.lock()
        if let baseTemplate {
            cacheLock.unlock()
            return baseTemplate
        }
        cacheLock.unlock()

        let candidates: [URL?] = [
            Bundle.main.url(forResource: "MenuBarGrok", withExtension: "svg"),
            Bundle.main.url(forResource: "MenuBarGrok", withExtension: "png"),
            // Dev fallback when running unpackaged binary next to Resources.
            URL(fileURLWithPath: "Resources/MenuBarGrok.svg"),
            URL(fileURLWithPath: "Resources/MenuBarGrok.png"),
        ]

        var loaded: NSImage?
        for case let url? in candidates {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let img = NSImage(contentsOf: url) {
                let sized = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
                    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
                    return true
                }
                sized.isTemplate = true
                loaded = sized
                break
            }
        }

        cacheLock.lock()
        baseTemplate = loaded
        cacheLock.unlock()
        return loaded
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
