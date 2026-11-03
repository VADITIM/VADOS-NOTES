# Known issues

Deliberate shortcuts, each with its ceiling and upgrade path.

- **The whole page redraws on every pan and zoom frame.** Fine for a few thousand strokes. Ceiling: very dense pages will drop frames while zooming. Upgrade: tile the committed ink into cached bitmaps per zoom level.
- **A live marker stroke draws above ink until it is committed.** The live layer sits on top; the stroke drops behind ink and text on pen-up.
- **The keyboard can cover a text block near the bottom of the screen.** Upgrade: offset the camera by the keyboard frame while editing.
- **Thumbnails render on the main thread.** Ceiling: a notebook with hundreds of pages opens slowly. Upgrade: render off-main into a cache keyed by page `updated`.
- **The page menu's Import slot is still disabled.** PDFs come in through New note; importing into an existing note is not built.
- **One sync holds every pending asset in memory.** The commit is built from all assets the remote lacks at once. Ceiling: a first sync with many large imports. Upgrade: stream each blob from disk and drop it once it is created.
- **Assets are never removed from the repository.** An asset whose import elements are all deleted stays in `assets/`. Upgrade: collect unreferenced assets with the tombstone compaction (spec 5.8).
- **PDF pages render at most 4096 px on their long side.** At extreme zoom they soften.
- **Dragging a tile does not scroll the grid at the edges**, on the iPad or on Windows. Upgrade: drive the scroll position from the drag location.
- **The iPad build is only compiled in CI.** It is written on Windows and checked by the `build` workflow on macOS; the first install may still show layout details that differ from Windows.
- **No app icon.** Make one with V/AS `guides/app-icon.md`.
- **Sync status in the sync sheet is read once.** It does not live-update while the sheet is open.
- **Windows and Linux export a raster PDF.** The page is a JPEG inside the PDF, up to 4 px per point. Upgrade: write vector paths for strokes and text.
- **The Windows and Linux visuals are checked by logic tests, not by eye.** The parity rebuild was exercised in a browser harness (navigation, drawing, undo taps, secondary nav, variations, lasso, text, menus, sync against a mock GitHub API); the motion was not watched frame by frame. Test with real clicks, not script-dispatched events: dispatched events skip hit-testing, which hid a `pointer-events` inheritance bug that made the nav dead.
- **Windows text wrapping is approximate.** Words wrap at spaces with canvas measurement; TextKit can break a line one word differently in rare cases.
- **Holding a preset in the secondary nav both arms it for removal and lifts its group.** Moving on reorders the group while the preset stays armed for its 2.4 s. Upgrade: disarm when a group lift starts.
- **Closing a note does not shrink back into its tile.** It cuts back to the folder. Upgrade: run the flight backwards from the page's transition, aimed at the tile's last frame.
- **The desktop parity port was checked in a browser, not in the Tauri window.** Typing, the `.md` and code navs, rendering, groups, dragging into and out of groups and reorder were driven in Chromium; IME input, the carry turn and the motion were not watched in the packaged app.
- **The clipboard is in-app only.** Cut and Copy keep elements in memory for the app run; they do not reach the system pasteboard and are lost on quit. Upgrade: write the elements as JSON with a custom pasteboard type.
- **The selection menu on Windows was checked by parts.** The menu layout and the library operations were run in a browser; a full lasso, tap and Cut was not clicked through, because the harness cannot draw a closed lasso.
