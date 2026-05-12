# Brand style

The visual language is set by the HUD shader; everything else (logo,
icon, README hero) is downstream of it.

## Colour palette

Source-of-truth: the R3F particle-ring fragment shader in
[`webview/`](../../webview/). Approximate hex values for static assets:

| Role | Hex | Use |
|------|-----|-----|
| Primary cyan | `#7DF9FF` | Particle ring at idle; primary accent; wordmark on dark. |
| Deep cyan | `#1FB8C8` | Ring at "listening"; secondary accent. |
| HUD navy | `#0A1929` | Background base; the "off-screen" colour. |
| HUD black | `#04080F` | Deepest background; vignette outer ring. |
| Warning amber | `#FFB347` | Soft / degraded subsystem state. |
| Critical red | `#FF4D4F` | Critical-severity probe failure; degraded chrome. |
| Soft white | `#E6F4F1` | Text on dark; the wordmark on dark. |

All assets must work on both `HUD navy` and pure white backgrounds.

## Typography

- **Wordmark / display:** [Eurostile / Bank Gothic family](https://fonts.adobe.com/fonts/eurostile)
  or a free analogue ([Saira Stencil One](https://fonts.google.com/specimen/Saira+Stencil+One),
  [Orbitron](https://fonts.google.com/specimen/Orbitron)). Geometric,
  wide, slightly stencilled — reads as "ops console" without tipping
  into kitsch.
- **UI body:** SF Pro (native macOS) — the HUD chat panel and the Dev
  Overlay use it; the README has no font opinion of its own (GitHub
  controls that).
- **Code / monospace:** SF Mono.

## Tone of voice

The repo's voice — README, commit messages, CLAUDE.md, in-code prose
— is *terse, technical, dryly opinionated, and slightly sardonic.*
Examples:

- ✓ "Eight NOT FAKED probes — `.unknown(reason:)` is the honest answer
  when we can't tell; `.ok` requires evidence."
- ✓ "Bus is the only legal way they talk."
- ✗ "Welcome to Jarvis! ✨ Our amazing AI-powered assistant is here to
  help."
- ✗ "Empowering developers to revolutionise their workflow."

Avoid:
- Hype words (revolutionise, empower, supercharge, amazing).
- Emoji except where structurally functional (`✓` / `✗` / boundary-gate
  state).
- Marketing copy that promises capabilities the boot-health probes
  would currently flag as degraded.
- Apologetic hedging ("we hope you find this useful") — state the thing
  and move on.

## Logo behaviour

When the logo is in motion (animated SVG, GIF, video), it pulses on the
same heartbeat as the HUD ring at idle — ~1.2 Hz, smooth sine, ±5%
brightness. Static logos render at the brightness midpoint.

## What we are NOT

- Not a chatbot brand. The product is an *ambient presence* — the
  visual language should feel like equipment, not a chat window.
- Not a corporate AI assistant brand. No gradients-on-gradients, no
  abstract human silhouettes.
- Not retro-futurist kitsch. Inspiration is the Iron Man HUD, not 80s
  arcade chrome — restrained, technical, expensive-feeling.
