# Logging

Library product `JarvisLogging`. Channel taxonomy + `swift-log` bootstrap + file rotation + the `Redact` helper.

## Key public types

| Type | Purpose |
|------|---------|
| `JarvisLogChannel` | Channel enum — `agent`, `tools`, `ui`, `system`, plus subsystem-specific |
| `LoggingBootstrap` | Wires `swift-log` to `OSLogHandler` (default) + `FileLogHandler` (rotation) |
| `OSLogHandler` | `os_log` backend |
| `FileLogHandler` | NDJSON rotating file backend |
| `FileRotatingWriter` | Size + time-based rotation |
| `Redact` | Mask helper for secrets in `logger.debug` strings |
| `LogPaths` | `~/Library/Application Support/Jarvis/logs/` resolver |
| `DateProvider` | Test seam for deterministic timestamps |

## Depends on

External only: `swift-log`.

## Used by

Every package and `App/`. This is the leaf logging dependency for the whole project.

## Key invariants / contracts

- **Bootstrap is idempotent.** Calling `LoggingBootstrap.bootstrap()` twice is a no-op.
- **Channels match the taxonomy in CLAUDE.md.** Don't invent ad-hoc subsystems — extend the enum.
- **`Redact` is the only sanitizer** for log strings that may contain secrets / PII / transcript text.
- **T-06-05-03: never log voice transcript text.** Enforced by code review + reading every Voice/Memory `logger.debug` site.
- **File rotation: size cap + age cap.** Old logs get rolled to `.gz` siblings, then pruned.

## Tests

XCTest. Round-trip log emission, rotation triggers, redact patterns.

## Notable files

- `Sources/JarvisLogging/JarvisLogChannel.swift` — channel enum
- `Sources/JarvisLogging/LoggingBootstrap.swift` — entry point
- `Sources/JarvisLogging/Redact.swift` — sanitizer
- `Sources/JarvisLogging/FileRotatingWriter.swift` — rotation
