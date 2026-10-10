# ADR 0001: Render the two-line menu bar label with NSStatusItem + a drawn NSImage

- Status: Accepted (M3, 2026-10-09)
- Context: PRD 8.1 asks for two lines in the menu bar, `[C] 62%` above `[X] 80%`, with threshold
  colors (orange at ≤30% left, red at ≤10%), automatic dark/light handling and a popover on click.

## Options tried

Both were built as minimal throwaway prototypes and run on macOS 26.6 (MacBook with a notch,
menu bar 33pt tall, 2x Retina, menu bar appearance `VibrantDark`).

| | 1. SwiftUI `MenuBarExtra`, `VStack` label | 2. `NSStatusItem` + `NSImage(size:flipped:drawingHandler:)` |
|---|---|---|
| Two lines render | **No.** Only the first line, at the default (large) size | **Yes**, both lines at 9.5pt monospaced digits |
| Colors | **Lost** (label is turned into a template; text came out white) | Kept: non-template image, colors chosen at draw time |
| Dark / light | Automatic (template) | Automatic: the drawing handler runs at draw time with the button's appearance, so `NSColor.labelColor` resolves per appearance. Verified by offscreen renders under `.aqua` and `.darkAqua` and on the real (dark) menu bar |
| Retina sharpness | n/a | Vector drawing at the backing scale; sharp |
| Popover position | Built in (`.window` style) | `NSPopover.show(relativeTo:of:preferredEdge: .minY)` on the button; standard placement under the item |
| Code size | Smallest | Small: one image builder + one controller (~100 lines) |

How it was checked: the prototypes printed their status item frames, and the real menu bar was
checked by eye (AppKit: two lines; SwiftUI: only `C 62%`, one line, large, white). `screencapture` was not
usable because the terminal has no Screen Recording permission, and snapshots of the app's own
status bar window come out blank on macOS 26 (the menu bar content is composited by the system).

## Decision

Use option 2.

- The label is a non-template `NSImage` with a drawing handler, rebuilt only when values change.
  Text uses `NSColor.labelColor`; warning/critical percentages use `systemOrange` / `systemRed`;
  missing values (`--`) use `secondaryLabelColor`. All are dynamic colors resolved at draw time,
  so no appearance observation is needed.
- Tool glyphs were neutral circular badges with a knocked-out letter ("C", "X"), drawn in code, with
  no Anthropic/OpenAI logos. (Superseded 2026-10-10: the label now draws the Claude mark and the
  OpenAI Blossom from their supplied SVG paths in `labelColor`, with these badges as the fallback;
  see docs/trademarks.md.) SF Symbols `c.circle.fill` / `x.circle.fill` exist and would also work,
  but drawing the badge directly avoids a separate tinting pass at 8pt.
- The popover is an `NSPopover` hosting SwiftUI content (`NSHostingController`). SwiftUI is still
  used for everything inside the popover. (Superseded in M5: the details open in a borderless panel
  instead of `NSPopover`, for memory reasons; see PRD §8.2 and docs/perf.md.)

## Consequences

- We own a small amount of drawing code (layout of 1–2 lines, badge, colors) and must keep the
  image height within the menu bar thickness (22–24pt; 33pt on notched displays — the image is
  vertically centered).
- Template-image niceties (automatic tinting when the menu bar is "reduced transparency" or
  highlighted) are replaced by dynamic system colors; highlighted state is drawn by the button.
- Fallback if a future macOS breaks two lines: a one-line label (`C 62 · X 80`) from the same
  label model.
