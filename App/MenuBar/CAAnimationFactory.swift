import AppKit
import QuartzCore

/// Pure helpers returning `CABasicAnimation`/`CAKeyframeAnimation` instances for the five
/// menu-bar `HudState` animations. Each helper consults
/// `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` and returns `nil` when Reduce
/// Motion is active — callers are responsible for the static fallback (UI-SPEC Surface 3
/// Reduce Motion fallback, lines 400-404).
///
/// Reference shapes: RESEARCH.md §Question 7 lines 818-858.
@MainActor
public enum CAAnimationFactory {
    /// Listening: breathing pulse ~0.8 Hz, scale 1.0 ↔ 1.04, sine ease.
    public static func makeBreath() -> CABasicAnimation? {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return nil }
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 1.0
        a.toValue = 1.04
        a.duration = 0.625
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return a
    }

    /// Thinking: inner-ring rotation, 1.5 s period, linear.
    public static func makeRotate() -> CABasicAnimation? {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return nil }
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = 2 * CGFloat.pi
        a.duration = 1.5
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        return a
    }

    /// Speaking: opacity shimmer, 900ms period, ease-in-out.
    public static func makeShimmer() -> CAKeyframeAnimation? {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return nil }
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [1.0, 0.65, 1.0]
        a.keyTimes = [0.0, 0.5, 1.0]
        a.duration = 0.9
        a.repeatCount = .infinity
        return a
    }

    /// AwaitingConfirmation: opacity glow, ~1 Hz, ease-in-out, higher amplitude than breath.
    public static func makeGlow() -> CABasicAnimation? {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return nil }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0
        a.toValue = 0.55
        a.duration = 0.5
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return a
    }

    /// 150ms crossfade between state animations (UI-SPEC Surface 3 transition spec).
    public static func makeStateCrossfade() -> CATransition {
        let t = CATransition()
        t.type = .fade
        t.duration = 0.15
        return t
    }
}
