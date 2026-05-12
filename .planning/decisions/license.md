# License decision — 2026-05-12

**Chose:** MIT License (already committed at `9b62db5`, confirmed here).

## Rationale

- **Project nature matches MIT's strengths.** Jarvis is a personal AI
  assistant intended for single-user single-machine use. The author has
  no commercial-licensing strategy, no patent portfolio to defend, and no
  preference for copyleft. The license should be permissive and friction-
  free — both for the author and for anyone curious enough to fork.
- **The interesting parts of the codebase are generic.** The agent loop,
  the typed JSON Bus, the MCP runtime, the boundary-gate scripts, the
  voice pipeline, and the R3F HUD scaffolding are all patterns other
  Swift / macOS / agent-stack authors might want to lift. MIT removes
  every barrier to that lift.
- **No contributor-agreement burden.** MIT does not require an explicit
  CLA, contributor license grant, or DCO sign-off. For a solo project
  that accepts the occasional drive-by PR via GitHub, MIT plus GitHub's
  default inbound-equals-outbound rule (ToS §D.6) is enough.
- **Compatible with everything in the dependency graph.** All current
  Swift Package Manager and pnpm dependencies are MIT, Apache-2.0, or
  BSD — no GPL/AGPL surfaces to consider. MIT downstream of Apache-2.0
  is a recognized clean combination.
- **Apple Silicon / ML model weights are separate.** The Orpheus, Qwen,
  and `nomic-embed-text` weights are not in this repo; their licenses
  govern themselves and are not affected by the host repo's license.
  This is consistent with how the wider open-source ML stack treats
  weights-as-data.

## Considered and rejected

- **Apache 2.0** — equivalent permissiveness, plus an explicit patent
  grant and a `NOTICE` mechanism. The patent-grant story is meaningful
  for larger projects with corporate contributors, but adds boilerplate
  noise (per-file headers, NOTICE handling) for negligible benefit on a
  solo personal project. **If a corporate contributor ever proposes a
  meaningful patch, revisit this decision.**
- **MPL-2.0** — file-level copyleft. Useful for projects that want to
  let proprietary integrators ship without re-licensing the whole
  product. The author has no such integration plans; the complexity
  isn't earning its keep.
- **AGPL-3.0** — copyleft including network use. Designed to force
  SaaS forks to share. Jarvis is single-user single-machine — there is
  no SaaS surface to protect. AGPL also signals "we don't want
  corporate adopters," which is the opposite of the message the public
  repo is sending.

## Implementation

- `LICENSE` at repo root (MIT, committed at `9b62db5`).
- **No per-file license headers.** MIT does not require them. The repo
  is large and adding 200+ identical headers would noise the diff for
  zero legal benefit. The repo-root `LICENSE` file plus the project name
  in the copyright line satisfies attribution.
- `README.md` "License" section points to `LICENSE` and names the
  license explicitly (this commit updates the section, which previously
  contradicted the actual MIT grant).
- `CONTRIBUTING.md` and `SECURITY.md` reference the license by name.
- The copyright line reads `Copyright (c) 2026 James Maes / KofTwentyTwo`.
  When 2027 ships, update to `2026-2027` rather than just incrementing.

## Revisit triggers

Open this decision back up if:
- A corporate contributor proposes a meaningful patch (consider Apache 2.0).
- The project gains a SaaS deployment surface (consider AGPL).
- A dependency adopts a license that is incompatible with MIT (re-examine
  the whole stack — but unlikely given the current dependency set).
