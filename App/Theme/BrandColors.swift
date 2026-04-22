import AppKit

/// Jarvis custom brand tokens. Kept minimal per UI-SPEC §Color — the menu-bar
/// icon stays pure template monochrome (D-13); the only branded color surface
/// in P1 is the HUD banner leading-edge accent stripe.
public enum BrandColor {
    /// Arc-reactor glow — used only for the HUD banner leading-edge accent stripe.
    ///
    /// - Light mode: `#1E88E5` at 85% opacity
    /// - Dark mode: `#64B5F6` at 90% opacity
    /// - Falls back to `NSColor.controlAccentColor` under Increase Contrast
    ///   (per UI-SPEC §Color line 113).
    public static var arcReactorGlow: NSColor {
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            return NSColor.controlAccentColor
        }
        return NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if isDark {
                return NSColor(red: 0x64/255.0, green: 0xB5/255.0, blue: 0xF6/255.0, alpha: 0.90)
            } else {
                return NSColor(red: 0x1E/255.0, green: 0x88/255.0, blue: 0xE5/255.0, alpha: 0.85)
            }
        })
    }
}
