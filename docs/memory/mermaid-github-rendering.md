# Mermaid Diagram Rendering on GitHub

## Known incompatible constructs

### `rect rgb()` blocks
- GitHub's Mermaid renderer does not reliably support `rect rgb(r, g, b) ... end` in sequence diagrams.
- Causes "svg element not in render tree" error — the diagram fails to render entirely.
- **Fix**: Remove `rect rgb()` blocks. Use `Note over participant1,participantN: Section label` as a section separator instead.

### `\n` in Note text
- Newline escape sequences in `Note over` or `Note right of` text are not reliably handled.
- **Fix**: Keep note text on a single line, or split into multiple `Note over` statements.

### Em dash `—` in Note text
- Unicode em dash can confuse the parser in some versions.
- **Fix**: Use plain hyphen `-` instead.

### Angle brackets `<` `>` in message or Note text
- Can be interpreted as HTML tags by the Mermaid SVG renderer.
- **Fix**: Remove angle brackets; use plain text (e.g. `trustDomain` not `<trustDomain>`).

## Safe constructs for GitHub Mermaid
- `sequenceDiagram` with `participant X as Label`
- `A->>B: message text`
- `A-->>B: message text` (dashed return arrow)
- `Note over A,B: single-line text`
- `Note right of A: single-line text`
- Participant labels with spaces and parentheses work fine (e.g. `participant CM as cert-manager (workload)`)
- Standard ASCII in all text

## Example pattern for section separators
```
Note over FirstParticipant,LastParticipant: Phase 2 - One-time platform setup
```
