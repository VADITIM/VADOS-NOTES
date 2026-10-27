# Known issues

Deliberate shortcuts, each with its ceiling and upgrade path.

- **The iPad app has not been compiled yet.** It was written on Windows. `ios/NotesCore` builds and its 44 tests pass on Windows; the app target needs a first build on a Mac or the `ios` GitHub Actions workflow.
- **The whole page redraws on every pan and zoom frame.** Fine for a few thousand strokes. Ceiling: very dense pages will drop frames while zooming. Upgrade: tile the committed ink into cached bitmaps per zoom level.
- **A live marker stroke draws above ink until it is committed.** The live layer sits on top; the stroke drops behind ink and text on pen-up.
- **The keyboard can cover a text block near the bottom of the screen.** Upgrade: offset the camera by the keyboard frame while editing.
- **Thumbnails render on the main thread.** Ceiling: a notebook with hundreds of pages opens slowly. Upgrade: render off-main into a cache keyed by page `updated`.
- **Import is a disabled slot.** Phase 4b.
- **No app icon.** Make one with V/AS `guides/app-icon.md`.
- **Sync status in the sync sheet is read once.** It does not live-update while the sheet is open.
- **Windows has no sync yet.** The sync sheet keeps owner, repository and branch but stores no token. Upgrade: port the journal and push protocol (phase 6) and keep the token in Credential Manager.
- **Windows text wrapping is approximate.** Words wrap at spaces with canvas measurement; TextKit can break a line one word differently in rare cases.
- The iPad app does not yet have the new nav (mutation, carrying, second navs), dark paper, precise erasing, finger gestures or the single pen. They were built on Windows first and are being ported.
