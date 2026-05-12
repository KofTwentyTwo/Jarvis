# Branding assets

What lives here: the brand surface for the public repo. Distinct from
[`assets/screenshots/`](../screenshots/) (product screenshots) — this
directory holds the **identity** layer: logo, social preview, hero shot.

## What we need (priority order)

### 1. Social preview — `social-preview.png` (1280 × 640, < 1 MB)

GitHub displays this in social-media unfurls (Slack, Twitter, Discord)
and on the repo's homepage card. Without it, GitHub uses the org avatar
— which says nothing about the project.

**Content shot list:**
- Background: dark navy / black, with a subtle radial gradient out from
  centre.
- Centre: the HUD particle ring at idle state (~60% of the canvas
  height), cyan with a faint cyan glow.
- Tagline overlaid below the ring: *"Personal AI assistant. Native
  macOS. Voice-first."*
- Top-right corner: `Jarvis` wordmark.
- Bottom-left corner: `KofTwentyTwo/Jarvis` in small monospace.

Upload via repo Settings → General → Social preview.

### 2. Logo / wordmark — `logo.svg` + `logo-light.svg` + `logo-dark.svg`

A single-glyph mark that reads at 16 px (favicon) and 1024 px (about-
window splash). The HUD particle ring is already iconic; consider a
stylised single ring with a centred dot — abstracted from the live
shader. Vector only; raster exports flow from it.

Variants:
- `logo.svg` — colour, the canonical version.
- `logo-light.svg` — black ink, transparent background, for light UIs.
- `logo-dark.svg` — white ink, transparent background, for dark UIs.

### 3. Hero shot / demo GIF — `hero.gif` (≤ 4 MB) or `hero.png` (1920 × 1080)

The one image we'd put at the very top of a Show HN post. Two options:
- **GIF:** a 4-6 second loop of the HUD: wake word triggers, ring
  switches idle → listening → thinking → speaking, chat text streams
  in. Sells the voice-loop without forcing a video click.
- **PNG:** a single composed frame showing the HUD ring + menu-bar icon
  + Dev Overlay open, on a real-looking desktop screenshot. Cheaper to
  produce; lower impact.

### 4. App icon source — `app-icon.svg` and `app-icon.png` (1024 × 1024)

The macOS app icon. Currently the project uses an empty placeholder.
Should match the logo glyph but framed in the Tahoe app-icon shape
(rounded square, subtle gradient, optional inner shadow). The 1024 ×
1024 PNG is what `Resources/Assets.xcassets/AppIcon.appiconset/` needs
as the master; AppKit downsamples the rest.

### 5. Banner — `banner.png` (3840 × 1280, optional)

A wide hero banner for the GitHub README at the very top. Strictly
optional; the project survives without it. If made, place at the very
top of `README.md` before the `# Jarvis` heading.

## Placeholder files

These `.todo` files are checked in as breadcrumbs so the directory
tree shows intent. Delete each one as the real asset lands.

- `logo.svg.todo`
- `social-preview.png.todo`
- `hero.gif.todo`
- `app-icon.png.todo`
- `banner.png.todo`

## Style reference

See [`STYLE.md`](STYLE.md) for the colour palette, typography, and tone
of voice. The HUD shader is the source of truth — match it.
