# Known issues

Deliberate shortcuts, each with its ceiling and upgrade path.

- **The whole page redraws on every pan and zoom frame.** Fine for a few thousand strokes. Ceiling: very dense pages will drop frames while zooming. Upgrade: tile the committed ink into cached bitmaps per zoom level.
- **A live marker stroke draws above ink until it is committed.** The live layer sits on top; the stroke drops behind ink and text on pen-up.
- **The keyboard can cover a text block near the bottom of the screen.** Upgrade: offset the camera by the keyboard frame while editing.
- **Thumbnails render on the main thread.** Ceiling: a notebook with hundreds of pages opens slowly. Upgrade: render off-main into a cache keyed by page `updated`.
- **The page menu's Import slot is still disabled.** PDFs come in through New note; importing into an existing note is not built.
- **Assets do not sync yet.** PDF assets stay on the device that imported them; another device shows grey placeholders. Upgrade: upload `assets/` through the journal before the pages that reference them (spec 7.3).
- **PDF pages render at most 4096 px on their long side.** At extreme zoom they soften.
- **Dragging a tile does not scroll the grid at the edges**, on the iPad or on Windows. Upgrade: drive the scroll position from the drag location.
- **The iPad build is only compiled in CI.** It is written on Windows and checked by the `build` workflow on macOS; the first install may still show layout details that differ from Windows.
- **No app icon.** Make one with V/AS `guides/app-icon.md`.
- **Sync status in the sync sheet is read once.** It does not live-update while the sheet is open.
- **Windows and Linux export a raster PDF.** The page is a JPEG inside the PDF, up to 4 px per point. Upgrade: write vector paths for strokes and text.
- **The Windows and Linux visuals are checked by logic tests, not by eye.** The parity rebuild was exercised in a browser harness (navigation, drawing, undo taps, secondary nav, variations, lasso, text, menus, sync against a mock GitHub API); the motion was not watched frame by frame. Test with real clicks, not script-dispatched events: dispatched events skip hit-testing, which hid a `pointer-events` inheritance bug that made the nav dead.
- **Windows text wrapping is approximate.** Words wrap at spaces with canvas measurement; TextKit can break a line one word differently in rare cases.
- **Folder and note groups live on one device.** They are stored in user defaults, not in the repository, so another device and Windows do not see them. Upgrade: an optional `groups` file per folder synced through the journal (a schema addition, to be agreed first).
- **Holding a preset in the secondary nav both arms it for removal and lifts its group.** Moving on reorders the group while the preset stays armed for its 2.4 s. Upgrade: disarm when a group lift starts.
- **Closing a note does not shrink back into its tile.** It cuts back to the folder. Upgrade: run the flight backwards from the page's transition, aimed at the tile's last frame.
- **Grouped folders and notes cannot be dragged.** Reordering and moving them goes through ungrouping or the Move sheet.
