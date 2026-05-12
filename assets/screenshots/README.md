# Screenshots

The root [`README.md`](../../README.md) references images from this
directory but currently ships zero of them — there's no point inventing
screenshots before there's something worth showing.

When a screenshot lands here, name it after its referent (`hud-ring-idle.png`,
not `Screen Shot 2026-05-12 at 4.32.png`), keep it under 800 KB (PNG with
`pngquant --quality 70-85`), and reference it from the README with a
descriptive alt-text.

## Shot list (priority order)

When the user has cycles, the highest-signal shots to capture:

1. **`hud-ring-idle.png`** — particle ring at rest, dim cyan. Establishes
   the visual identity in the README's hero slot.
2. **`hud-ring-thinking.gif`** *(optional, animated)* — ring rotating during
   a streamed Opus turn. Sells "this is alive."
3. **`hud-ring-states.png`** — 2×2 grid of the four agent states (idle /
   listening / thinking / speaking) for the "Subsystems" section's HUD
   row.
4. **`status-panel.png`** — menu-bar → *Status…* showing the eight
   boot-health probes with mixed states (some `.ok`, one `.soft`, one
   `.unknown`). Demonstrates the NOT-FAKED probe culture concretely.
5. **`degradation-banner.png`** — a non-dismissible HUD banner with a
   critical-severity failure (e.g., "Memory store unreachable — Jarvis
   will not remember new facts this session"). Shows the strict-mode
   escalation in action.
6. **`devoverlay-turns.png`** — the Dev Overlay's Turns tab during a
   live conversation, with one expanded turn showing the streamed events
   timeline. Useful for the "Non-functional requirements" section.
7. **`devoverlay-bus.png`** — the Bus tab with a recent message trace.
   Useful when documenting the Bus contract.
8. **`menu-bar.png`** — close-up of the menu-bar icon in normal state
   beside its red degraded variant. Pairs with the boot-health probe
   diagram.

## Diagrams (different concern)

Architecture / lifecycle / install-order diagrams live as inline
**mermaid** blocks inside `README.md` and `ARCHITECTURE.md` — they render
natively on GitHub and stay in sync with the code without anybody
re-exporting an SVG. Don't replace them with rasterized exports.

If a diagram outgrows mermaid (≳ 20 nodes or needs precise layout), the
right move is to author it in [Excalidraw](https://excalidraw.com), export
both the `.excalidraw` source and a `.svg` into this directory, and
reference the SVG from the README. The `.excalidraw` source is what keeps
the diagram editable.
