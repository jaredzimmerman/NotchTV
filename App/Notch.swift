import AppKit
import QuartzCore

enum NotchGeometry {
    /// The built-in display: the only screen with a top safe-area inset.
    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    /// The notch in global screen coordinates: the gap between the two unobscured
    /// top areas, as tall as the top safe-area inset.
    static func notchRect(on screen: NSScreen) -> NSRect? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let height = screen.safeAreaInsets.top
        let width = screen.frame.width - left.width - right.width
        guard width > 0, height > 0 else { return nil }
        return NSRect(x: screen.frame.minX + left.width,
                      y: screen.frame.maxY - height,
                      width: width, height: height)
    }

    /// A rectangle hanging from the top edge with only its bottom corners rounded.
    /// Every path has the same elements, so CoreAnimation can morph between them.
    static func hangingPath(_ r: CGRect, radius: CGFloat) -> CGPath {
        let rad = min(radius, r.width / 2, r.height)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
        p.addQuadCurve(to: CGPoint(x: r.minX + rad, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - rad, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + rad), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Receives the clicks and the pointer entering the notch. Everything it shows is a
/// black shape: inside the cutout it is hidden by the camera housing, and because it is
/// opaque the window server routes clicks on it here rather than to the menu bar.
/// Transparent parts of the panel let clicks through.
final class OverlayView: NSView {
    var onEnter: (() -> Void)?
    var onClick: ((NSPoint) -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var hoverZone = NSRect.zero { didSet { if hoverZone != oldValue { updateTrackingAreas() } } }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        if !hoverZone.isEmpty {
            addTrackingArea(NSTrackingArea(rect: hoverZone,
                                           options: [.mouseEnteredAndExited, .activeAlways],
                                           owner: self))
        }
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onMenu?(event); return }
        onClick?(convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
}

/// The notch, extended: hover widens it into two wings (this TV on the left, what a click
/// will do on the right); messages drop down below it.
final class NotchOverlay {
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var menuAnchor: NSView { view }

    private let panel: NSPanel
    private let view = OverlayView()
    private let shape = CAShapeLayer()
    private let leftIcon = CALayer()
    private let rightIcon = CALayer()
    private let messageIcon = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let message: NSStackView

    private var notch = NSRect.zero  // global coordinates
    private var hovering = false
    private var messageShowing = false
    private var messageWidth: CGFloat = 0
    private var hideMessageWork: DispatchWorkItem?
    private var hoverTimer: Timer?
    private var outsideSince: Date?
    private var rightSymbol = "playpause.fill"
    private var deviceAvailable = false
    private var busy = false

    private let wing: CGFloat = 38      // how far each side grows on hover
    private let drop: CGFloat = 26      // how far a message hangs below the notch
    private let slack: CGFloat = 240    // panel width beyond the notch
    private let iconPoint: CGFloat = 13

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true

        view.wantsLayer = true
        panel.contentView = view
        let root = view.layer!
        shape.fillColor = NSColor.black.cgColor
        root.addSublayer(shape)
        for icon in [leftIcon, rightIcon] {
            icon.contentsGravity = .center
            icon.opacity = 0
            root.addSublayer(icon)
        }

        messageIcon.contentTintColor = .white
        messageIcon.imageScaling = .scaleNone
        messageLabel.textColor = .white
        messageLabel.font = .systemFont(ofSize: 12, weight: .medium)
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.maximumNumberOfLines = 1
        message = NSStackView(views: [messageIcon, messageLabel])
        message.orientation = .horizontal
        message.spacing = 6
        message.alignment = .centerY
        message.alphaValue = 0
        view.addSubview(message)

        view.onEnter = { [weak self] in self?.setHovering(true) }
        view.onClick = { [weak self] point in self?.click(at: point) }
        view.onMenu = { [weak self] event in self?.onMenu?(event) }
        setLeftIcon()
        setRightIcon()
    }

    // MARK: Placement

    func place(over notch: NSRect?, scale: CGFloat) {
        guard let notch else { panel.orderOut(nil); return }
        self.notch = notch
        let size = NSSize(width: notch.width + slack, height: notch.height + drop + 6)
        panel.setFrame(NSRect(x: notch.midX - size.width / 2, y: notch.maxY - size.height,
                              width: size.width, height: size.height), display: false)
        view.frame = NSRect(origin: .zero, size: size)
        for icon in [leftIcon, rightIcon] { icon.contentsScale = scale }
        layout(animated: false)
        panel.orderFrontRegardless()
    }

    /// The notch in the view's coordinates.
    private var notchLocal: NSRect {
        NSRect(x: (view.bounds.width - notch.width) / 2, y: view.bounds.height - notch.height,
               width: notch.width, height: notch.height)
    }

    /// The black shape right now. Idle it sits a few points inside the hardware cutout.
    private var shapeRect: NSRect {
        let n = notchLocal
        var r = hovering ? n.insetBy(dx: -wing, dy: 0)
                         : (messageShowing ? n : n.insetBy(dx: 5, dy: 0))
        if messageShowing {
            let width = min(max(r.width, messageWidth + 40), view.bounds.width)
            r = NSRect(x: n.midX - width / 2, y: n.minY - drop, width: width, height: n.height + drop)
        }
        return r
    }

    private var cornerRadius: CGFloat { messageShowing ? 14 : (hovering ? 11 : 8) }

    // MARK: Hover

    private func setHovering(_ on: Bool) {
        guard on != hovering, notch != .zero else { return }
        hovering = on
        outsideSince = nil
        if on {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.checkPointer() }
            RunLoop.main.add(timer, forMode: .common)
            hoverTimer = timer
        } else {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
        layout(animated: true)
    }

    /// Collapse once the pointer has been off the shape briefly (a short grace period
    /// keeps a pass over the rounded corners from flickering it shut).
    private func checkPointer() {
        let local = shapeRect.insetBy(dx: -2, dy: -2).offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        if local.contains(NSEvent.mouseLocation) {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) > 0.12 { setHovering(false) }
        } else {
            outsideSince = Date()
        }
    }

    private func click(at point: NSPoint) {
        // Clicks on the message hanging below the notch do nothing.
        guard point.y >= notchLocal.minY - 1 else { return }
        if !hovering { setHovering(true) }
        onClick?()
    }

    // MARK: Wing icons

    private func symbol(_ name: String, palette: [NSColor] = [.white]) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: iconPoint, weight: .semibold)
            .applying(.init(paletteColors: palette))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    private func setLeftIcon() {
        // appletv.fill has two layers: the  tv logo first, then the box. One colour for
        // both paints a blank square, so the logo is drawn black to read as a cut-out.
        let box = NSColor.white.withAlphaComponent(deviceAvailable ? 1 : 0.45)
        let image = symbol("appletv.fill", palette: [.black, box])
        leftIcon.contents = image
        leftIcon.bounds = CGRect(origin: .zero, size: image?.size ?? .zero)
    }

    private func setRightIcon() {
        let image = symbol(rightSymbol)
        rightIcon.contents = image
        rightIcon.bounds = CGRect(origin: .zero, size: image?.size ?? .zero)
    }

    /// Dims the Apple TV glyph when no TV is connected.
    func setDeviceAvailable(_ available: Bool) {
        guard available != deviceAvailable else { return }
        deviceAvailable = available
        setLeftIcon()
    }

    /// The glyph for what a click will do. `animated` marks a change the click caused.
    func setNextAction(_ name: String, animated: Bool) {
        guard name != rightSymbol else { return }
        rightSymbol = name
        guard animated, hovering, !reduceMotion else { setRightIcon(); return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.18
        rightIcon.add(fade, forKey: "swap")
        setRightIcon()
        let bump = CAKeyframeAnimation(keyPath: "transform.scale")
        bump.values = [0.7, 1.12, 1.0]
        bump.keyTimes = [0, 0.55, 1]
        bump.duration = 0.32
        bump.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        rightIcon.add(bump, forKey: "bump")
    }

    /// A click is on its way to the TV: the action glyph breathes until the answer.
    func setBusy(_ on: Bool) {
        guard on != busy else { return }
        busy = on
        applyBusyPulse()
    }

    /// The pulse animates opacity, so it would override the collapsed state's 0:
    /// it only runs while the wings are open.
    private func applyBusyPulse() {
        let running = rightIcon.animation(forKey: "busy") != nil
        if busy && hovering {
            guard !running else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.35
            pulse.toValue = 0.85
            pulse.duration = 0.5
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            rightIcon.add(pulse, forKey: "busy")
        } else if running {
            rightIcon.removeAnimation(forKey: "busy")
        }
    }

    // MARK: Messages

    /// Text below the notch (errors, pairing). `hold == nil` keeps it until replaced or hidden.
    func showMessage(_ symbolName: String, _ text: String, hold: TimeInterval? = 2.4) {
        guard notch != .zero else { return }
        hideMessageWork?.cancel()
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        messageIcon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        messageLabel.stringValue = text
        messageWidth = min(message.fittingSize.width, view.bounds.width - 60)
        messageShowing = true
        layout(animated: true)
        if let hold {
            let work = DispatchWorkItem { [weak self] in self?.hideMessage() }
            hideMessageWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
        }
    }

    func hideMessage() {
        hideMessageWork?.cancel()
        guard messageShowing else { return }
        messageShowing = false
        layout(animated: true)
    }

    // MARK: Layout

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func layout(animated: Bool) {
        guard notch != .zero else { return }
        let n = notchLocal
        let rect = shapeRect
        view.hoverZone = hovering ? rect : n
        applyBusyPulse()

        // Wing icons: centred in each wing; hidden under the notch edge when collapsed,
        // so opening the wings slides them out of the cutout.
        let midY = n.midY
        let out = hovering ? wing / 2 : 0
        let leftPosition = CGPoint(x: n.minX - out, y: midY)
        let rightPosition = CGPoint(x: n.maxX + out, y: midY)

        let path = NotchGeometry.hangingPath(rect, radius: cornerRadius)
        if animated, !reduceMotion {
            morph(to: path)
            CATransaction.begin()
            CATransaction.setAnimationDuration(hovering ? 0.34 : 0.2)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1))
            leftIcon.position = leftPosition
            rightIcon.position = rightPosition
            leftIcon.opacity = hovering ? 1 : 0
            rightIcon.opacity = hovering ? 1 : 0
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(!animated)
            CATransaction.setAnimationDuration(0.15)
            shape.path = path
            leftIcon.position = leftPosition
            rightIcon.position = rightPosition
            leftIcon.opacity = hovering ? 1 : 0
            rightIcon.opacity = hovering ? 1 : 0
            CATransaction.commit()
        }

        message.frame = NSRect(x: n.midX - messageWidth / 2, y: n.minY - drop + 4,
                               width: messageWidth, height: drop - 8)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = messageShowing ? 0.22 : 0.12
            message.animator().alphaValue = messageShowing ? 1 : 0
        }
    }

    private func morph(to path: CGPath) {
        let from = shape.presentation()?.path ?? shape.path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = path
        CATransaction.commit()
        let spring = CASpringAnimation(keyPath: "path")
        spring.fromValue = from
        spring.toValue = path
        spring.mass = 1
        spring.stiffness = 340
        spring.damping = 26
        spring.duration = spring.settlingDuration
        shape.add(spring, forKey: "morph")
    }
}
