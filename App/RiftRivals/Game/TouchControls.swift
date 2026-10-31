import UIKit

/// Converts touch state into one `PlayerInput` per simulation tick.
/// Button taps are latched so a press shorter than one tick is never lost,
/// and each press is delivered exactly once.
final class InputSampler: LocalInputSource {
    private let lock = NSLock()
    private var stick = CGVector(dx: 0, dy: 0)
    private var pulseHeld = false
    private var dashHeld = false
    private var pulseLatched = false
    private var dashLatched = false

    func setStick(_ v: CGVector) { lock.lock(); stick = v; lock.unlock() }
    func setPulse(_ down: Bool) { lock.lock(); if down && !pulseHeld { pulseLatched = true }; pulseHeld = down; lock.unlock() }
    func setDash(_ down: Bool) { lock.lock(); if down && !dashHeld { dashLatched = true }; dashHeld = down; lock.unlock() }
    func reset() { lock.lock(); stick = .zero; pulseHeld = false; dashHeld = false; pulseLatched = false; dashLatched = false; lock.unlock() }

    func sampleInput(forTick tick: Int32) -> PlayerInput {
        lock.lock(); defer { lock.unlock() }
        let pulse = InputSampler.resolve(held: pulseHeld, latched: &pulseLatched, last: &lastPulse)
        let dash = InputSampler.resolve(held: dashHeld, latched: &dashLatched, last: &lastDash)
        return PlayerInput(stickX: Double(stick.dx), stickY: Double(stick.dy), pulse: pulse, dash: dash)
    }

    /// The simulation fires on the press *edge*. A latched tap reports "down"
    /// for one tick; if the previous tick was already down, one "up" tick is
    /// inserted first so the new press still produces an edge.
    private static func resolve(held: Bool, latched: inout Bool, last: inout Bool) -> Bool {
        var out = held
        if latched {
            if last { out = false } else { out = true; latched = false }
        }
        last = out
        return out
    }

    private var lastPulse = false
    private var lastDash = false
}

/// Full-screen multi-touch layer: floating joystick on one side, PULSE and
/// DASH on the other (mirrored for left-handed players).
final class TouchControlsView: UIView {
    let sampler: InputSampler
    private let stickBase = CAShapeLayer()
    private let stickKnob = CAShapeLayer()
    private let pulseButton = CAShapeLayer()
    private let dashButton = CAShapeLayer()
    private let pulseLabel = CATextLayer()
    private let dashLabel = CATextLayer()
    private let pulseCooldown = CAShapeLayer()
    private let dashCooldown = CAShapeLayer()
    private var stickTouch: UITouch?
    private var stickOrigin: CGPoint = .zero
    private var pulseTouch: UITouch?
    private var dashTouch: UITouch?
    private let stickRadius: CGFloat = 62
    var teamColor: UIColor = .white { didSet { refreshColors() } }
    var dashEnabled = true { didSet { dashButton.opacity = dashEnabled ? 1 : 0.25; dashLabel.opacity = dashButton.opacity } }

    init(sampler: InputSampler) {
        self.sampler = sampler
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        for l in [stickBase, stickKnob, pulseButton, dashButton, pulseCooldown, dashCooldown] { layer.addSublayer(l) }
        for (t, text) in [(pulseLabel, "PULSE"), (dashLabel, "DASH")] {
            t.string = text
            t.font = UIFont.systemFont(ofSize: 14, weight: .heavy)
            t.fontSize = text == "PULSE" ? 15 : 12
            t.alignmentMode = .center
            t.contentsScale = UIScreen.main.scale
            t.foregroundColor = UIColor.white.withAlphaComponent(0.9).cgColor
            layer.addSublayer(t)
        }
        stickBase.fillColor = UIColor.white.withAlphaComponent(0.05).cgColor
        stickBase.strokeColor = UIColor.white.withAlphaComponent(0.25).cgColor
        stickBase.lineWidth = 2
        stickKnob.strokeColor = UIColor.white.withAlphaComponent(0.6).cgColor
        stickKnob.lineWidth = 2
        for c in [pulseCooldown, dashCooldown] {
            c.fillColor = UIColor.clear.cgColor
            c.lineWidth = 4
            c.lineCap = .round
            c.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        }
        stickBase.opacity = 0.0
        stickKnob.opacity = 0.0
        refreshColors()
        accessibilityLabel = "Game controls. Left side: move. Right side: Pulse and Dash."
    }

    required init?(coder: NSCoder) { fatalError() }

    private var leftHanded: Bool { Preferences.shared.leftHanded }

    private func refreshColors() {
        stickKnob.fillColor = teamColor.withAlphaComponent(0.55).cgColor
        pulseButton.fillColor = teamColor.withAlphaComponent(0.28).cgColor
        pulseButton.strokeColor = teamColor.withAlphaComponent(0.9).cgColor
        pulseButton.lineWidth = 2.5
        dashButton.fillColor = UIColor.white.withAlphaComponent(0.08).cgColor
        dashButton.strokeColor = UIColor.white.withAlphaComponent(0.55).cgColor
        dashButton.lineWidth = 2
    }

    private var pulseCenter: CGPoint {
        let inset = safeAreaInsets
        let x = leftHanded ? inset.left + 96 : bounds.width - inset.right - 96
        return CGPoint(x: x, y: bounds.height - 92)
    }
    private var dashCenter: CGPoint {
        let p = pulseCenter
        return CGPoint(x: p.x + (leftHanded ? 92 : -92), y: p.y + 30)
    }
    private let pulseRadius: CGFloat = 50
    private let dashRadius: CGFloat = 34

    private var defaultStickOrigin: CGPoint {
        let inset = safeAreaInsets
        let x = leftHanded ? bounds.width - inset.right - 130 : inset.left + 130
        return CGPoint(x: x, y: bounds.height - 120)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulseButton.path = UIBezierPath(arcCenter: pulseCenter, radius: pulseRadius, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        dashButton.path = UIBezierPath(arcCenter: dashCenter, radius: dashRadius, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        pulseLabel.frame = CGRect(x: pulseCenter.x - 50, y: pulseCenter.y - 9, width: 100, height: 20)
        dashLabel.frame = CGRect(x: dashCenter.x - 40, y: dashCenter.y - 8, width: 80, height: 18)
        if stickTouch == nil { drawStick(origin: defaultStickOrigin, knob: defaultStickOrigin, active: false) }
        CATransaction.commit()
    }

    private func drawStick(origin: CGPoint, knob: CGPoint, active: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stickBase.path = UIBezierPath(arcCenter: origin, radius: stickRadius, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        stickKnob.path = UIBezierPath(arcCenter: knob, radius: 28, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        stickBase.opacity = active ? 1 : 0.45
        stickKnob.opacity = active ? 1 : 0.45
        CATransaction.commit()
    }

    /// Cooldown rings (0 = ready, 1 = just used).
    func setCooldowns(pulse: CGFloat, dash: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        func ring(_ layer: CAShapeLayer, center: CGPoint, radius: CGFloat, frac: CGFloat) {
            if frac <= 0.001 { layer.path = nil; return }
            let start = -CGFloat.pi / 2
            layer.path = UIBezierPath(arcCenter: center, radius: radius + 6, startAngle: start,
                                      endAngle: start + .pi * 2 * (1 - frac), clockwise: true).cgPath
        }
        ring(pulseCooldown, center: pulseCenter, radius: pulseRadius, frac: pulse)
        ring(dashCooldown, center: dashCenter, radius: dashRadius, frac: dash)
        pulseButton.opacity = pulse > 0 ? 0.55 : 1
        if dashEnabled { dashButton.opacity = dash > 0 ? 0.45 : 1 }
        CATransaction.commit()
    }

    private func isStickSide(_ p: CGPoint) -> Bool { leftHanded ? p.x > bounds.width * 0.5 : p.x < bounds.width * 0.5 }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            if hypot(p.x - pulseCenter.x, p.y - pulseCenter.y) < pulseRadius + 26 && pulseTouch == nil {
                pulseTouch = t
                sampler.setPulse(true)
                pulseButton.transform = CATransform3DMakeScale(1, 1, 1)
            } else if hypot(p.x - dashCenter.x, p.y - dashCenter.y) < dashRadius + 20 && dashTouch == nil && dashEnabled {
                dashTouch = t
                sampler.setDash(true)
            } else if isStickSide(p) && stickTouch == nil {
                stickTouch = t
                stickOrigin = Preferences.shared.fixedJoystick ? defaultStickOrigin : p
                updateStick(p)
            } else if !isStickSide(p) && pulseTouch == nil {
                // Anywhere else on the action side also pulses — forgiving under pressure.
                pulseTouch = t
                sampler.setPulse(true)
            }
        }
    }

    private func updateStick(_ p: CGPoint) {
        var dx = p.x - stickOrigin.x
        var dy = p.y - stickOrigin.y
        let len = hypot(dx, dy)
        if len > stickRadius {
            // Drag the base along so the stick never "runs out".
            if !Preferences.shared.fixedJoystick {
                stickOrigin.x += dx / len * (len - stickRadius)
                stickOrigin.y += dy / len * (len - stickRadius)
            }
            dx = dx / len * stickRadius
            dy = dy / len * stickRadius
        }
        let dead: CGFloat = 6
        var v = CGVector(dx: dx / stickRadius, dy: -dy / stickRadius) // UIKit y is down; simulation y is up
        if hypot(dx, dy) < dead { v = .zero }
        sampler.setStick(v)
        drawStick(origin: stickOrigin, knob: CGPoint(x: stickOrigin.x + dx, y: stickOrigin.y + dy), active: true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where t == stickTouch { updateStick(t.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches) }

    private func end(_ touches: Set<UITouch>) {
        for t in touches {
            if t == stickTouch {
                stickTouch = nil
                sampler.setStick(.zero)
                drawStick(origin: defaultStickOrigin, knob: defaultStickOrigin, active: false)
            }
            if t == pulseTouch { pulseTouch = nil; sampler.setPulse(false) }
            if t == dashTouch { dashTouch = nil; sampler.setDash(false) }
        }
    }

    func releaseAll() {
        stickTouch = nil; pulseTouch = nil; dashTouch = nil
        sampler.reset()
        setNeedsLayout()
    }
}
