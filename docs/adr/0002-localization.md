# ADR 0002: Localize with .strings in a separate TokenGlanceText module

- Status: Accepted (M5, 2026-10-09)
- Context: PRD 8.7 asks for English and Korean (plus "follow the system"), covering the tooltip,
  popover, settings, errors, the hook consent dialog and notifications. Core must return states and
  values, not sentences. The project builds with SwiftPM, including on machines with only the
  Command Line Tools.

## Decision

1. **`.strings` files, not a String Catalog.** Checked with the CLT toolchain (Swift 6.3.3): SwiftPM
   copies a `Localizable.xcstrings` resource as-is (no `*.lproj` is generated), so lookups fall
   back to the key. `en.lproj/ko.lproj/Localizable.strings` are processed correctly. A test checks
   that both tables have the same keys and the same format specifiers per key.
2. **A `TokenGlanceText` library target** owns all user-facing text and builds it from Core values
   (`ToolState`, `UnavailableReason`, `PathValidation`, `LimitNotification`, …). It is a library so
   the texts are unit-tested in both languages; the app only displays what it returns.
3. **Language chosen per `Localizer` instance**, not through the process locale: the table for the
   selected language is loaded directly, and numbers/dates use that language's `Locale`. Switching
   the language in settings applies immediately; no restart is needed.
4. **Resource bundle location.** `scripts/bundle-app.sh` copies
   `token-glance_TokenGlanceText.bundle` into `Contents/Resources`, and `Localizer` looks there
   first. The generated `Bundle.module` accessor is not used in the app: it looks next to the app's
   top level (which code signing does not allow) and in the absolute build path of the machine that
   built it. `--print-state` reports where the strings were loaded from.

## Consequences

- New strings need an entry in both tables; the key/specifier test catches omissions.
- System dialogs (permission prompts) follow the macOS language, not the app setting.
- Plurals are avoided by using compact units ("2h 10m" / "2시간 10분"); a `.stringsdict` would be
  needed if full-word plurals are introduced.
