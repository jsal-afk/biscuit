import AppKit
#if BISCUIT_SMOKE || BISCUIT_NATIVE_ACCOUNT_QA
import CoreGraphics
#endif

/// Keeps QA presentation on the explicitly selected built-in display before ordering windows.
/// Production uses AppKit's normal placement and modal behavior.
@MainActor
enum BiscuitPresentation {
#if BISCUIT_SMOKE || BISCUIT_NATIVE_ACCOUNT_QA
    static func qaScreen() -> NSScreen? {
        guard let raw = ProcessInfo.processInfo.environment["BISCUIT_SMOKE_CAPTURE_DISPLAY_ID"],
              let id = UInt32(raw), id > 0,
              CGDisplayIsBuiltin(id) != 0, CGDisplayIsActive(id) != 0 else {
            reject("missing or unavailable built-in display")
            return nil
        }
        var match: NSScreen?
        for screen in NSScreen.screens {
            guard (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id else { continue }
            guard match == nil, screen.frame.contains(screen.visibleFrame),
                  screen.visibleFrame.width > 0, screen.visibleFrame.height > 0 else {
                reject("invalid built-in visible frame")
                return nil
            }
            match = screen
        }
        if match == nil { reject("built-in display is not connected") }
        return match
    }

    private static func reject(_ reason: String) {
        fputs("BISCUIT QA presentation refused: \(reason)\n", stderr)
    }

    private static func constrained(_ proposed: NSRect, to visible: NSRect, centered: Bool = false) -> NSRect {
        let size = NSSize(width: min(proposed.width, visible.width), height: min(proposed.height, visible.height))
        let origin = centered
            ? NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
            : NSPoint(x: min(max(proposed.minX, visible.minX), visible.maxX - size.width),
                      y: min(max(proposed.minY, visible.minY), visible.maxY - size.height))
        return NSRect(origin: origin, size: size)
    }
#endif

    @discardableResult
    static func prepare(_ window: NSWindow, centered: Bool = false) -> Bool {
#if BISCUIT_SMOKE || BISCUIT_NATIVE_ACCOUNT_QA
        guard let screen = qaScreen() else { return false }
        let frame = constrained(window.frame, to: screen.visibleFrame, centered: centered)
        guard frame.width > 0, frame.height > 0 else { return false }
        window.setFrame(frame, display: false)
        guard screen.visibleFrame.contains(window.frame) else {
            reject("window cannot fit inside the built-in visible frame")
            return false
        }
#endif
        return true
    }

    static func center(_ window: NSWindow?) {
        guard let window else { return }
#if BISCUIT_SMOKE || BISCUIT_NATIVE_ACCOUNT_QA
        _ = prepare(window, centered: true)
#else
        window.center()
#endif
    }

    @discardableResult
    static func show(_ window: NSWindow?, key: Bool = true) -> Bool {
        guard let window, prepare(window) else { return false }
        if key { window.makeKeyAndOrderFront(nil) }
        else { window.orderFrontRegardless() }
        return true
    }

    static func setFrame(_ frame: NSRect, for window: NSWindow, display: Bool, animate: Bool = false) {
#if BISCUIT_SMOKE || BISCUIT_NATIVE_ACCOUNT_QA
        guard let screen = qaScreen() else { return }
        window.setFrame(constrained(frame, to: screen.visibleFrame), display: display, animate: animate)
#else
        window.setFrame(frame, display: display, animate: animate)
#endif
    }

    static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
#if BISCUIT_SMOKE || BISCUIT_NATIVE_ACCOUNT_QA
        if alert.buttons.isEmpty {
            alert.addButton(withTitle: NSLocalizedString("OK", bundle: Bundle(for: NSAlert.self), comment: ""))
        }
        alert.layout()
        guard let screen = qaScreen(), screen.visibleFrame.width >= alert.window.frame.width,
              screen.visibleFrame.height >= alert.window.frame.height,
              prepare(alert.window, centered: true) else { return .abort }
        // NSApplication centers an *invisible* modal window. Order the prepared window first;
        // its documented already-visible path only makes it key, without another center().
        let responseTarget = AlertResponseTarget()
        for (index, button) in alert.buttons.enumerated() {
            button.tag = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index
            button.target = responseTarget
            button.action = #selector(AlertResponseTarget.respond(_:))
        }
        alert.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { alert.window.orderOut(nil) }
        return withExtendedLifetime(responseTarget) { NSApp.runModal(for: alert.window) }
#else
        return alert.runModal()
#endif
    }

    static func beginSheet(_ alert: NSAlert, for parent: NSWindow,
                           completionHandler: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) {
#if BISCUIT_SMOKE || BISCUIT_NATIVE_ACCOUNT_QA
        alert.layout()
        guard prepareSheet(alert.window, for: parent) else {
            completionHandler(.abort)
            return
        }
        parent.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
#endif
        alert.beginSheetModal(for: parent, completionHandler: completionHandler)
    }

    static func beginSheet(_ panel: NSSavePanel, for parent: NSWindow,
                           completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
#if BISCUIT_SMOKE || BISCUIT_NATIVE_ACCOUNT_QA
        guard prepareSheet(panel, for: parent, resizable: true) else {
            completionHandler(.abort)
            return
        }
        parent.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
#endif
        panel.beginSheetModal(for: parent, completionHandler: completionHandler)
    }

    static func begin(_ panel: NSSavePanel, for parent: NSWindow?,
                      completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
#if BISCUIT_SMOKE || BISCUIT_NATIVE_ACCOUNT_QA
        guard let parent else {
            reject("file panel has no owning window")
            completionHandler(.abort)
            return
        }
        beginSheet(panel, for: parent, completionHandler: completionHandler)
#else
        panel.begin(completionHandler: completionHandler)
#endif
    }

#if BISCUIT_SMOKE || BISCUIT_NATIVE_ACCOUNT_QA
    private static func prepareSheet(_ sheet: NSWindow, for parent: NSWindow, resizable: Bool = false) -> Bool {
        guard let screen = qaScreen(), parent.isVisible, !parent.isMiniaturized,
              parent.attachedSheet == nil else {
            reject("sheet has no available visible parent")
            return false
        }
        let visible = screen.visibleFrame
        let available = NSSize(width: visible.width - 32, height: visible.height - 96)
        guard available.width > 0, available.height > 0 else {
            reject("built-in visible frame is too small for a sheet")
            return false
        }

        if resizable {
            let minimum = sheet.minSize
            guard minimum.width <= available.width, minimum.height <= available.height else {
                reject("native file panel minimum size exceeds the built-in visible frame")
                return false
            }
            // Use the current pre-begin frame, which may already reflect restored/expanded state.
            // Without a measurable frame, there is no safe footprint to present.
            var panelFrame = sheet.frame
            guard panelFrame.width > 0, panelFrame.height > 0 else {
                reject("native file panel has no measurable pre-begin frame")
                return false
            }
            panelFrame.size.width = min(max(panelFrame.width, minimum.width), available.width)
            panelFrame.size.height = min(max(panelFrame.height, minimum.height), available.height)
            sheet.setFrame(panelFrame, display: false)
            let fittedFrame = sheet.frame
            guard fittedFrame.width <= available.width, fittedFrame.height <= available.height,
                  fittedFrame.width >= minimum.width, fittedFrame.height >= minimum.height else {
                reject("native file panel could not be prebounded inside the built-in visible frame")
                return false
            }
            let contentFrame = NSWindow.contentRect(
                forFrameRect: NSRect(origin: .zero, size: fittedFrame.size),
                styleMask: sheet.styleMask
            )
            let contentMinimum = sheet.contentMinSize
            guard contentMinimum.width <= contentFrame.width,
                  contentMinimum.height <= contentFrame.height else {
                reject("native file panel content minimum size exceeds its bounded frame")
                return false
            }
            // Cap user/content-driven resizing at the fitted frame. AppKit also permits some
            // explicit setFrame calls to bypass these limits; the fitted frame above is the
            // pre-display bound and native-panel sizing remains a required runtime check.
            sheet.maxSize = fittedFrame.size
            sheet.contentMaxSize = contentFrame.size
        } else if sheet.frame.width <= 0 || sheet.frame.height <= 0
                    || sheet.frame.width > available.width || sheet.frame.height > available.height {
            reject("alert sheet has no safe measurable frame")
            return false
        }

        // AppKit versions may center a sheet in its parent or attach it below the title bar.
        // A top-aligned host containing the full sheet footprint is safe for both placements.
        let hostMargin = NSSize(width: 32, height: 96)
        let requiredHost = NSSize(
            width: sheet.frame.width + hostMargin.width,
            height: sheet.frame.height + hostMargin.height
        )
        guard requiredHost.width <= visible.width, requiredHost.height <= visible.height else {
            reject("sheet footprint cannot fit with a safe parent margin")
            return false
        }
        let original = constrained(parent.frame, to: visible, centered: true)
        let hostSize = NSSize(
            width: max(original.width, requiredHost.width),
            height: max(original.height, requiredHost.height)
        )
        let hostFrame = NSRect(
            x: visible.midX - hostSize.width / 2,
            y: visible.maxY - hostSize.height,
            width: hostSize.width,
            height: hostSize.height
        )
        parent.setFrame(hostFrame, display: false)
        guard visible.contains(parent.frame),
              parent.frame.width >= requiredHost.width,
              parent.frame.height >= requiredHost.height,
              sheet.frame.width <= available.width,
              sheet.frame.height <= available.height else {
            reject("sheet or parent could not be prebounded inside the built-in visible frame")
            return false
        }
        return true
    }

    @MainActor
    private final class AlertResponseTarget: NSObject {
        @objc func respond(_ sender: NSButton) {
            NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: sender.tag))
        }
    }
#endif
}
