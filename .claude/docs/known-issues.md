# Known issues

Deliberate shortcuts, each with its ceiling and upgrade path.

- **The whole page redraws on every pan and zoom frame.** Fine for a few thousand strokes. Ceiling: very dense pages will drop frames while zooming. Upgrade: tile the committed ink into cached bitmaps per zoom level.
- **A live marker stroke draws above ink until it is committed.** The live layer sits on top; the stroke drops behind ink and text on pen-up.
- **The keyboard can cover a text block near the bottom of the screen.** Upgrade: offset the camera by the keyboard frame while editing.
- **Thumbnails render on the main thread.** Ceiling: a notebook with hundreds of pages opens slowly. Upgrade: render off-main into a cache keyed by page `updated`.
- **The page menu's Import slot is still disabled.** PDFs come in through New note; importing into an existing note is not built.
- **Assets do not sync yet.** PDF assets stay on the device that imported them; another device shows grey placeholders. Upgrade: upload `assets/` through the journal before the pages that reference them (spec 7.3).
- **PDF pages render at most 4096 px on their long side.** At extreme zoom they soften.
- **Dragging a tile on the iPad does not scroll the grid at the edges.** Windows does. Upgrade: drive the scroll position from the drag location.
- **The iPad build is only compiled in CI.** It is written on Windows and checked by the `build` workflow on macOS; the first install may still show layout details that differ from Windows.
- **No app icon.** Make one with V/AS `guides/app-icon.md`.
- **Sync status in the sync sheet is read once.** It does not live-update while the sheet is open.
- **Windows has no sync yet.** The sync sheet keeps owner, repository and branch but stores no token. Upgrade: port the journal and push protocol (phase 6) and keep the token in Credential Manager.
- **Windows text wrapping is approximate.** Words wrap at spaces with canvas measurement; TextKit can break a line one word differently in rare cases.
