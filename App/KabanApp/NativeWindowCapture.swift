#if KABAN_QA
import AppKit

@MainActor enum NativeWindowCapture {
    /// Capture the real WindowGroup, including its title bar safe area.
    static func capture() async throws -> NSBitmapImageRep {
        for _ in 0..<40 {
            if let window = NSApp.windows.first(where: {
                $0.styleMask.contains(.titled) && $0.contentView != nil && $0.frame.width >= 1040
            }), let content = window.contentView?.superview ?? window.contentView {
                window.layoutIfNeeded()
                content.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                content.layoutSubtreeIfNeeded()
                func invalidate(_ view: NSView) {
                    view.needsDisplay = true
                    view.layer?.setNeedsDisplay()
                    for child in view.subviews { invalidate(child) }
                }
                invalidate(content)
                content.displayIfNeeded()
                guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { break }
                content.cacheDisplay(in: content.bounds, to: bitmap)
                guard let sheet = window.attachedSheet, let sheetView = sheet.contentView?.superview,
                      let sheetBitmap = sheetView.bitmapImageRepForCachingDisplay(in: sheetView.bounds) else { return bitmap }
                sheet.layoutIfNeeded(); sheetView.layoutSubtreeIfNeeded(); invalidate(sheetView)
                sheetView.cacheDisplay(in: sheetView.bounds, to: sheetBitmap)
                let combined = NSImage(size: content.bounds.size)
                combined.lockFocus()
                bitmap.draw(in: content.bounds)
                NSColor.black.withAlphaComponent(0.12).setFill()
                NSBezierPath(rect: content.bounds).fill()
                sheetBitmap.draw(in: NSRect(x: sheet.frame.minX - window.frame.minX, y: sheet.frame.minY - window.frame.minY,
                                           width: sheetView.bounds.width, height: sheetView.bounds.height))
                combined.unlockFocus()
                guard let data = combined.tiffRepresentation, let result = NSBitmapImageRep(data: data) else { throw NSError(domain: "NativeWindowCapture", code: 5) }
                return result
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "NativeWindowCapture", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Main application window was not available"])
    }
}
#endif
