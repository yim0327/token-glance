# Third-party marks

Token Glance shows two third-party marks in its menu bar label, only to identify which service a
number belongs to: the Claude mark next to the Claude Code value, the OpenAI Blossom next to the
Codex value. The app's own name, icon and branding are not based on them.

- The marks and the names "Claude", "Anthropic", "OpenAI" and "Codex" are trademarks of their
  respective owners. All rights in them stay with those owners.
- Token Glance is not affiliated with, sponsored, endorsed or approved by Anthropic or OpenAI.
- The MIT license covers this project's code only. It grants no right to use the third-party
  marks; anyone reusing the code or the files below needs to check the owners' terms themselves.
- No approval from Anthropic or OpenAI has been requested or confirmed for this use. The
  "not affiliated" notice is not a substitute for permission.

## Files

| File in `Sources/TokenGlanceText/Resources/Marks/` | Source | SHA-256 |
|---|---|---|
| `claude-spark.svg` | Anthropic press kit (`https://www.anthropic.com/press-kit`, "Anthropic media resources.zip", file `Anthropic logos/Claude logos/3 Claude Spark/SVG/Claude Spark - Clay.svg`), downloaded 2026-10-10 | `6d53db4be375e899c937c26cf16684a80d6e869b1928d72b37748bef2560e219` |
| `openai-blossom.svg` | `OAI_OpenAI-Blossom_Black.svg`, supplied by the maintainer when asked for the official download from OpenAI's brand page (`https://openai.com/brand/`). The file carries no download URL and the page could not be opened by automated tools (HTTP 403), so where it was downloaded from is not recorded or verified independently. A white variant with the same path was supplied as well. | `75c1e9fffa5e8c437bec1d67197a73992bca45d166c6ff23215185dea8fae92a` |

Both files are stored byte for byte as downloaded (only renamed). The Claude mark used is the
general Claude mark ("Claude Spark"), not the separate Claude Code logo in the same press kit.

## How they are drawn

- The path of each file is drawn as is and scaled uniformly; nothing is redrawn, thickened or
  reshaped. It is fitted to the 10 pt (two lines) or 13 pt (one line) square by the path's own
  bounds, so the empty margin in the OpenAI file (its clear space) is not kept at this size.
- Both are filled in one color, the system label color: white on a dark menu bar, black on a
  light one, like a template image. For the Claude mark this differs from the supplied color
  (Clay, `#D97757`); the press kit has no one-color version of this mark. For OpenAI it matches the
  supplied black and white variants. This one-color rendering is Token Glance's choice, not a
  variant approved by either owner.
- Warning colors (orange, red) apply only to the numbers, never to the marks.
- If a file is missing or cannot be read, the label falls back to the neutral "C" / "X" badges.

## Conditions found (2026-10-10)

- Anthropic trademark guidelines (`https://www.anthropic.com/legal/trademark-guidelines`): use only
  as specifically permitted and in materials approved beforehand; no changes to color, font or
  proportion; no implied sponsorship, endorsement or affiliation. **Not resolved** for this use:
  no approval was requested, and the one-color rendering changes the color.
- OpenAI brand guidelines (`https://openai.com/brand/`): read only through search summaries, since
  the page returned HTTP 403 to automated tools. They say to use the logo only in connection with
  OpenAI services, exactly as supplied, without modification, and to acknowledge OpenAI's
  ownership. **Not verified** against the full page.

The maintainer chose to ship the marks with these points open. Nothing here should be read as
permission from either company or as a statement that the use is legally allowed.
