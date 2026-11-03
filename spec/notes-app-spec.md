# VAD/OS Notes: Spec and Agent Roadmap

A GoodNotes replacement for iPad and Windows. Ink is written on the iPad, typing happens on the PC, and both sync through a private GitHub repo. Built as a VAD/OS app and styled with the V/AS design language.

---

## 1. Goals

- Cleaner, more consistent UX than GoodNotes, with no inconsistencies that bother the user.
- Handwriting on iPad, typing on Windows/Linux. No handwriting-to-text conversion.
- Notes stay editable on the PC and sync with the iPad automatically.
- Lean scope: basics only. Extra features stay out of the app.
- UI elements taken from VAD/OS Gallery, especially the mutating nav element.
- Private GitHub repo as the single sync backend.

## 2. Non-goals

- No handwriting recognition or ink-to-text conversion.
- No pressure sensitivity. Strokes have constant width.
- No templates. One built-in paper style only.
- No collaboration or sharing features. The repo stays private.

## 3. Core concepts

### 3.1 Infinite canvas on an A4 grid

- A page has no fixed size. Elements use one unbounded coordinate space.
- Extent is expressed in whole A4 cells: `cols` and `rows`.
- Expanding adds one column at the right or one row at the bottom: 1×1 → 2×1 → 2×2 → 3×2, and so on.
- Expansion only changes the visible extent and the cell boundary lines. No stored element moves.
- Expansion is triggered by a button: "add column" or "add row" in the page menu adds one cell along that axis.
- Beside each add button sits a remove button. It removes the one column or row under the hold point: elements whose centre lies in it are deleted, later columns or rows move back by one cell, and the axis shrinks by one. It is never below one cell, arms first like every destructive slot, and is one undo step.
- All coordinates and lengths in a page file are millimetres. One A4 cell is 210 × 297, and cell (c, r) spans x ∈ [210c, 210(c+1)), y ∈ [297r, 297(r+1)).

### 3.2 Layers

Rendering sorts by layer first, then by `order` within a layer. Creation time does not decide stacking.

| Layer | Contents |
|---|---|
| `paper` | Background and squared guides (view-level, not stored as elements) |
| `import` | Imported PDF and image pages. Always behind markers, ink, and text. |
| `marker` | Highlighters and markers. Always behind ink and text. |
| `ink` | Pen and pencil strokes |
| `text` | Typed text blocks |
| `overlay` | Shapes and anything that must sit above everything |

Markers stay in a fixed layer behind text. This behaviour is the point of the marker tool.

### 3.3 Ink

- Strokes are vector, drawn on a canvas. They stay sharp at any zoom.
- Stored as raw points with a constant width. No pressure, no tilt.
- The SVG path or canvas path is generated at render time from the points. Points are the source of truth.
- Tools: pen, pencil, marker. Width, colours and opacity per tool live in `shared/tokens.json`. Opacity is not stored per stroke; renderers apply the tool's opacity from the token file.
- Paths are drawn as quadratic curves through the midpoints of consecutive points, with round caps and joins. Both renderers use this rule so a page looks the same everywhere.

### 3.4 Guides

- Squared (graph) paper, toggleable on or off.
- Drawn procedurally by the viewer. Not stored as elements.
- Toggling is a view setting and never changes the page file.
- Grid spacing is a separate setting from the A4 cell grid.

## 4. Page schema (v1)

### 4.1 Page file

One JSON file per page.

```json
{
  "schema_version": 1,
  "id": "p_01H...",
  "notebook": "nb_01H...",
  "updated": "2026-10-25T13:45:00Z",
  "device": "ipad-01",
  "deleted": false,
  "extent": { "cols": 2, "rows": 1 },
  "extent_updated": "2026-10-25T13:40:00Z",
  "elements": []
}
```

`extent_updated` is optional. It is written whenever the extent changes and is the extent's own clock (5.5).

### 4.2 Element

Every element has the same base fields.

```json
{
  "id": "e_01H...",
  "type": "stroke",
  "layer": "ink",
  "order": 12,
  "tool": "pen",
  "color": "#1A1A1A",
  "width": 1.2,
  "points": [[120.5, 300.2], [121.0, 300.4], [121.8, 300.9]],
  "updated": "2026-10-25T13:44:10Z",
  "device": "ipad-01",
  "deleted": false
}
```

Text blocks use `type: "text"`, `layer: "text"`, and a `content` field instead of `points`. They also carry `box` (top-left corner and wrapping width, in millimetres) and `font_size` (millimetres):

```json
{
  "id": "e_01H...",
  "type": "text",
  "layer": "text",
  "order": 3,
  "color": "#1A1A1A",
  "content": "Typed on either device",
  "box": { "x": 20.0, "y": 30.0, "width": 80.0 },
  "font_size": 4.2,
  "updated": "2026-10-25T13:44:10.120Z",
  "device": "pc-01",
  "deleted": false
}
```

Timestamps are UTC ISO 8601 with milliseconds. Readers also accept them without fractional seconds.

### 4.4 Repository layout

```
notebooks/<notebook id>/notebook.json      { schema_version, id, title, updated, device, deleted, color?, icon?, parent?, order?, group? }
notebooks/<notebook id>/pages/<page id>.json
groups/<group id>.json                     { schema_version, id, parent?, title, kind, order?, updated, device, deleted }
assets/<sha256>
```

A group gathers folders (`kind: "folders"`) or notes (`kind: "notes"`) inside one folder (`parent`, absent at the top level) into a stack. Membership is stored on the member, not on the group: a notebook or page header carries the optional `group` ID it belongs to. A member counts only while its group is live, of its kind, and in the same folder as the member; anything else reads as ungrouped. Group IDs use the prefix `g_`.

Notebooks are shown as folders. `parent` nests a folder inside another; a missing or deleted parent puts it at the top level. A page header may carry an optional `title`, `color` and `icon`; they sit in the header lines in sorted-key order and are left out when absent. Pages are ordered by their ID, which is a ULID and therefore sorts by creation time. Files are written with sorted keys and one element per line, so the same state always produces the same bytes.

### 4.3 Rules

- Element IDs are unique and immutable once created.
- `order` breaks ties within a layer. It is stored, not derived from array position.
- A deleted element stays in the file as a tombstone: `deleted: true` with an updated timestamp.
- `schema_version` must be checked on load. Unknown versions are read-only, never overwritten.

## 5. Sync

### 5.1 Model

- The device is the source of truth for what the user has written.
- GitHub is a replica that catches up in batches.
- One file per page. Two devices editing different pages never conflict.

### 5.2 Local journal

- Every change is appended to a local, append-only journal before the UI updates.
- Each entry has a device ID, a timestamp, and the change.
- Journal entries are removed only after GitHub confirms the push that contains them.
- Page state is rebuilt from the last synced snapshot plus the journal.

### 5.3 Flush policy

A page is marked dirty on every change. A flush happens when any of these is true:

- **Idle:** 5 seconds with no input on that page. Pen-down, keystroke, or gesture resets the timer.
- **Max age:** 60 seconds since the first unflushed change, even while writing continues.
- **Lifecycle:** the app goes to the background, the window closes, or the user switches notebooks.

Dirty pages flush together as one commit.

### 5.4 Push protocol

1. Read the remote head SHA of the notebook branch.
2. Build the changed page files from local state.
3. Create blobs, tree, and commit on top of the head (GitHub Git Data API).
4. Fast-forward the branch ref.
5. On success: mark journal entries as synced and remove them.
6. On rejection (branch moved): fetch changed pages, merge (section 5.5), retry from step 1. Backoff 1 s, 2 s, 4 s, capped at 30 s.

A Git Data API commit is atomic: either all pages in a flush land or none do.

### 5.5 Merge rules

- **Elements:** union by ID. Two devices adding elements never conflict.
- **Deletions:** tombstones. A tombstone wins over a copy of the same element without the deletion.
- **Edits to existing elements** (moving or changing a text block): latest `updated` wins, per element.
- **Page metadata** (title, colour, icon, order, group): latest `updated` wins.
- **Groups:** a group file is latest `updated` wins, and a deleted group wins over a live copy. Because membership lives on each member, two devices adding different notes to one group never conflict.
- **Extent:** latest `extent_updated` wins; a stamped extent wins over an unstamped one; two unstamped extents (or an exact tie) merge to their union. `updated` cannot decide it, because every element edit moves the page's `updated`, so a device that drew on a stale copy would bring a removed column back.

### 5.6 Offline

- Writing never waits on the network.
- Flushes queue in the journal, which can hold weeks of changes.
- On reconnect: pull, merge, push, in order.

### 5.7 Failure handling

| Case | Behaviour |
|---|---|
| Token revoked or expired | Pause sync, keep journal, show "sync paused" |
| Corrupt remote JSON | Keep local copy, preserve the bad remote file in the repo, flag it. Never overwrite silently. |
| Partial push | Not possible with atomic commits. If it happens, treat as corrupt. |
| Repeated 409s | Back off, keep journal, retry later |

### 5.8 Auth and storage

- Fine-grained personal access token scoped to the single notes repo.
- Windows: Windows Credential Manager.
- iPad: iOS Keychain.
- Tombstone compaction is a later task. It needs per-device sync cursors, which the journal already provides.

## 6. Platforms

### 6.1 iPad (native)

- SwiftUI app.
- Ink input from Apple Pencil and finger, rendered as constant-width strokes. Pressure is ignored.
- Custom canvas: touches are captured and stored as points, and strokes are drawn from those points. No PencilKit.
- Text blocks are fully editable on both platforms. The iPad can also create text blocks with the on-screen or a hardware keyboard.

### 6.2 Windows and Linux (Tauri)

- Tauri, matching the VAD/OS stack.
- Canvas-based renderer for ink and layers. Pan, zoom, squared guides.
- Full text editing for text blocks.
- Linux is a secondary target after Windows.

### 6.3 Shared design

- V/AS tokens (colors, type, spacing, motion curves) exported as one JSON file. Both clients consume it.
- Mutating nav element from VAD/OS Gallery is specified once and implemented per platform.

### 6.4 Design language and haptic menus

- **No Apple Human Interface Guidelines.** Apple's default look, with its blur, glass, and shader effects, is not used. It is resource-heavy and adds visual noise without improving use.
- **Flat and fast.** No blur, no shaders, no glass materials. Animation is short and uses V/AS motion curves only.
- **Menus are VAD/OS haptic menus.** They open on long press and are not the iOS context menu or sheet style.
- **Fixed positions.** Each action has one slot in a menu, and that slot never moves. Options are not reordered by usage or context. Muscle memory is the goal.
- **Semantic colour.** Colour encodes meaning, not decoration. One meaning per colour across the whole app. Initial set (to be confirmed in the token file):
  - Destructive (delete, clear): red
  - Create or add: green
  - Navigation and page movement: blue
  - View settings (guides, zoom): neutral grey
  - Ink tools (pen, pencil, marker): the stroke colour itself
  - Import and asset actions: amber
- **Haptics are iPad only.** Windows has no standard haptic feedback, so every menu action also has a visual state change. Nothing depends on vibration to be understood.
- **Shared tokens.** Colour meanings, slot positions, and motion curves live in `shared/tokens.json`, so both platforms follow one definition.

## 7. PDF and image import and export

- Each A4 cell exports as one page, ordered left to right, then top to bottom.
- Double-column and double-row extents split into single A4 sheets.
- Strokes that cross a cell boundary must be clipped on each sheet. Behaviour to be confirmed.
- A4 is the standard. Other sizes are out of scope for v1.

### 7.1 Import

- Accepts PDF (multi-page) and images (PNG, JPEG, and similar).
- Each imported page becomes one `import` element on a page. A multi-page PDF fills consecutive A4 cells in page order, so a worksheet stays in sequence.
- The source file is stored once as an asset, named by content hash. Re-importing the same file reuses it.
- PDF pages are rasterized at the current zoom level for display (PDFKit on iPad, pdf.js or PDFium on Windows), so they stay sharp when zoomed. The asset keeps the original vector content.
- The import element stores only placement, never a baked-in image:

```json
{
  "id": "e_01H...",
  "type": "import",
  "layer": "import",
  "order": 0,
  "asset": "sha256:9f3a...",
  "source_page": 0,
  "source_name": "worksheet.pdf",
  "source_size_mm": [215.9, 279.4],
  "placement": { "x": 0, "y": 0, "scale": 1.0 },
  "fit": "fit_cell",
  "updated": "2026-10-25T13:50:00Z",
  "device": "ipad-01",
  "deleted": false
}
```

### 7.2 Scaling mismatches

Teachers often produce worksheets that were scaled on export or print: content shrunk into a corner, enlarged past the A4 edge, or a Letter page dropped onto an A4 cell. The app keeps the source page size as a fact and the placement as an editable transform, so scaling is never destructive.

- **Fit modes:** `original` (1:1 physical size), `fit_cell` (scale to the A4 cell with margin, keeping aspect ratio), and `fit_width` (fill the cell width).
- **Manual correction:** a numeric scale and drag-to-move on a selected import element, so content can be fixed by hand.
- **Re-fitting** changes only `fit`, `placement`, and `updated`. The asset is never touched, and the change syncs like any other edit.
- **Default:** a non-A4 page starts as `fit_cell`, centred in its cell. A page already at A4 starts as `original`.
- **Later:** auto-crop to content bounds to remove blank margins before fitting. Not in v1.

### 7.3 Asset storage and sync

- Assets live in `assets/` in the repo, named by content hash. They are immutable, so they never conflict.
- Assets upload before any page that references them, so no page points to a missing file.
- Asset uploads go through the journal too. An import made offline syncs once the connection returns.
- Assets upload in the same atomic commit as the first page that references them (or in an earlier one), never after it.
- On every sync a device downloads each asset its live pages reference and it does not hold, and checks the bytes against the hash in the name before keeping them.
- GitHub rejects single files over 100 MB, and large files slow the repo down. v1 caps each imported file at 50 MB (`sync.asset_limit_megabytes`). Git LFS is the fallback for anything larger.

## 8. Explicit non-features (v1)

- Templates and paper choice
- Handwriting conversion
- Pressure and tilt
- Sharing and collaboration
- Auto-crop of imported pages
- Multiple paper styles

---

## 9. Roadmap for the Agent

Each phase has a clear acceptance check. Do not start a phase until the previous one passes.

### Phase 0: Foundations
- Create the repo structure: `spec/`, `ios/`, `windows/`, `shared/`.
- Put this spec in `spec/` as the reference.
- Export V/AS tokens to `shared/tokens.json`.
- **Accept:** the spec and token file exist and are reviewed.

### Phase 1: Page format and sync core (no UI)
- Implement the page schema, validation, and `schema_version` checks.
- Implement the local journal (append, replay, mark synced).
- Implement the merge rules as a pure function with unit tests.
- Implement the push protocol against the GitHub Git Data API, with a mock backend for tests.
- **Accept:** merge tests cover union, tombstones, LWW, and concurrent-edit cases. Push tests cover 409 and retry. No UI is needed.

### Phase 2: iPad prototype
- SwiftUI app with a single page.
- Ink capture from Pencil and finger, constant width, no pressure.
- Save and load the page JSON through the journal.
- **Accept:** a page drawn on iPad round-trips through JSON unchanged. Draw a page, kill the app, reopen: strokes are intact.

### Phase 3: Windows canvas viewer
- Tauri app, canvas renderer, loads the same JSON.
- Layers drawn in the defined order. Marker stays behind ink and text.
- Pan, zoom, A4 cell boundaries, squared guide toggle.
- **Accept:** a page from iPad renders identically on Windows, including layer order.

### Phase 4: Infinite canvas and expansion
- Extent in A4 cells, grown one column or row at a time.
- Expansion trigger implemented per the open decision.
- **Accept:** expanding 1×1 → 2×1 → 2×2 → 4×2 keeps all elements in place.

### Phase 4b: PDF and image import
- Asset store: content-hashed uploads, dedupe, size cap, uploads through the journal.
- Import element type with placement transform and fit modes.
- Renderers: PDFKit on iPad, pdf.js or PDFium on Windows, rasterized at the current zoom.
- Manual scale and drag-to-move on import elements.
- **Accept:** a multi-page PDF imports in page order. A Letter PDF fits its cell by default. Changing fit does not change the asset hash. A worksheet scaled down on export can be corrected to fill its cell. Markers and ink draw above the imported page on both platforms.

### Phase 5: Text blocks
- Text block element type on the Windows side.
- Typed text saved as text-layer elements.
- iPad behaviour for text per the open decision.
- **Accept:** typed text on Windows appears in the right layer and syncs back.

### Phase 6: Sync loop end to end
- Idle, max-age, and lifecycle flush triggers.
- Background sync on both platforms.
- Offline queue and reconnect.
- **Accept:** write on iPad, sync, edit the same page on Windows, sync, and see both changes on iPad without manual steps. Test with airplane mode and an expired token.

### Phase 7: PDF export
- A4-cell split with left-to-right, top-to-bottom ordering.
- Clipping rule for crossing strokes as decided.
- **Accept:** a 4×2 page exports as 8 A4 pages in the right order.

### Phase 8: Polish and VAD/OS integration
- Mutating nav element from VAD/OS Gallery.
- V/AS motion and layout pass.
- Tombstone compaction.
- **Accept:** side-by-side review against the spec on both platforms.

---

## 10. Open decisions

1. ~~**Expansion trigger**~~: decided, a button (section 11).
2. ~~**Grid spacing**~~: provisionally fixed at 5 mm (section 11).
3. ~~**Idle timer**~~: provisionally fixed at 5 seconds (section 11).
4. ~~**Tools**~~: provisionally a fixed set with fixed colours (section 11).
5. ~~**iPad canvas**~~: decided, custom (section 11).
6. ~~**Text on iPad**~~: decided, fully editable (section 11).
7. **PDF clipping:** how to split strokes that cross a cell boundary?
8. ~~**Idle definition**~~: provisionally a full 5 second pause (section 11).
9. ~~**Import size cap**~~: decided, 50 MB per file (section 11).
10. **Multi-page import placement:** expand the extent automatically to fit all pages, or fill existing empty cells first?

## 11. Decision log

- Ink stays ink. No handwriting recognition.
- No pressure sensitivity. Constant stroke width.
- Vector ink on a canvas. Points stored, path generated at render time.
- Infinite canvas with A4 cell extents, expanding by doubling one axis.
- Layers are fixed per element type. Marker always behind text.
- No templates. One paper style with a squared-guide toggle.
- Squared guides are a view setting, not stored data.
- GitHub repo stays private.
- Sync: local journal first, idle 5 s, max age 60 s, lifecycle flush, batched commits with fast-forward ref updates.
- Merge: union for elements, tombstones for deletes, LWW for edits and metadata.
- Storage: fine-grained PAT in Credential Manager (Windows) and Keychain (iPad).
- PDF and image import in v1. Source pages are immutable assets; placement is an editable transform, so scaling corrections are never destructive.
- Import layer sits below markers, ink, and text, so annotations always stay above imported worksheets.
- No Apple Human Interface Guidelines. Flat design, no blur, no shaders, no glass. Own VAD/OS haptic menus.
- Haptic menus use fixed slot positions that never reorder, and semantic colours with one meaning across the app.
- Haptics on iPad only. Every menu action also has a visual state change for Windows.
- V/AS base register.
- Expansion trigger: a button in the page menu (add column, add row).
- iPad canvas: custom, not PencilKit.
- Text blocks: fully editable on iPad and PC; the iPad can create them.
- Page coordinates are millimetres.
- Tools: fixed set (pen, pencil, marker) with four colours each and a fixed width per tool, defined in `shared/tokens.json`. Plus a stroke eraser that tombstones whole strokes.
- Grid spacing: fixed 5 mm.
- Idle timer: fixed 5 seconds. A pen lift is not idle; only 5 seconds without any input is.
- One sync branch (default `main`) for every notebook. One file per page keeps devices apart.
- Undo of an erase re-creates the stroke under a new ID, because a tombstone always wins a merge.
- The paper is light (`#EFEEE9`). It is content, like a photo in VAD/OS Gallery, so it owns its colour; the chrome around it stays on the V/AS ground.
- Notebooks are folders and can nest (`parent`). Pages are notes and carry an optional name, colour and icon. Moving a note to another folder writes it under a new page ID there and tombstones the old file, because the folder is part of the path.
- Top bars float over the content as overlays on the flat panel colour (no blur); the page fits below them.
- Folders and notes carry an optional integer `order` and can be rearranged and moved by drag and drop. Folder screens have no bottom nav; "Add folder" and "Add note" lead their grids, and a search field in the top bar finds folders and notes by name.
- Ink and text stay on the paper: strokes start on it and are clipped to its edge. The paper has rounded corners (4 mm).
- Text blocks are Markdown, rendered on the canvas and stored raw. New notes start from a sheet: a name and Blank or PDF. PDF notes place one page per A4 cell; on dark paper white PDF pages display inverted without changing the asset.
- The camera stays near the paper. Cell lines can be turned off. One release ships the Windows exe and the unsigned iPad IPA.
- The iPad app is edge to edge with a transparent status bar. A finger pans the canvas and the Pencil draws; text and the lasso take either. The page fits centred and can be pushed well past its edges.
- Folders and notes rename in the haptic menu or in place in their top bar; a note shows its created date (DD/MM/YY, read from the page ID) beside its name. Back sits beside settings on every screen. Undo and redo sit at the bottom left.
- The haptic menu is a narrow vertical list whose corner sits at the finger, with icons, divided sections and delete last. The page's "…" opens a secondary nav (delete, import | add column, add row | guides, cell lines), which opens and closes like GALLERY's viewer date pill and stays open while drawing.
- Tool sizes are set by a quick slide along the nav, which turns it into a slider for the selected tool; the secondary nav keeps only presets. Two- and three-finger single taps undo and redo; there are no undo buttons. A note opens fitted whole, and the colour wheel opens beside its button.
- The nav is carried by its end grips, never collapses, steers clear of the other UI and the keyboard, and its tools and secondary-nav groups reorder by holding them.
- A lasso selects every stroke, text and imported page it touches and moves them as one undo step. The selection stays across tool changes until a finger presses the canvas.
- Folder tiles show their icon in the centre and their colour as the outline; notes lie in a grid of equal tiles, one per note whatever its page columns and rows, each showing the note's first page.
- Folders and notes can be grouped inside a folder as GALLERY-style stacks, synced through `groups/<id>.json` with membership on each member. Opening a note flies out of its tile.
- An optional ASCII background drifts behind the folder screens, tilted to 14:10, still or moving, in a chosen colour. Guides keep their phase across vertically joined cells. Stroke ranges: pen 0.5–50 px, marker 1–100 px, eraser 1–80 px.
- The lasso starts only with the Pencil; a selection moves with one finger anywhere, scales by pinching on it, and a tap on it offers "Resize to equal px".
- Both navs share one enter (circle pop, widen, then elements) and one leave; pops turn on the vertical axis instead of bouncing. Returning from a note keeps the shared chrome still. Add folder sits under Add note; a 1×2 note is never shorter than a 2×2 one; naming sheets ride up on the keyboard with the name selected.
- Tapping a pen or marker colour offers three duller or more saturated variations beside it; picking one replaces the colour. On the canvas the note name is a small bare line at the top. A finger pan glides briefly after release. Nav elements arrive and switch faster, and the size slide needs a deliberate drag along the nav. The ASCII background is spaced wider, a little stronger, moves without costing frames and shows around the paper too.
- ASCII rows are staggered, its opacity is set in Settings, and its motion can exclude the canvas. Imported PDFs draw only where visible. One-finger and two-finger pans both glide.
- Colour variations are made once from the tapped swatch, stay while the user picks among them, mark the main colour with a short line, and use the nav's own enter and leave; any canvas touch closes them and the wheel. The nav has no grip glyphs and can be dragged off its edge while a secondary nav is open. Leaving a screen plays the chrome's leave first; the canvas title, folder and date each arrive with the label reveal. PDF pages are composited as layers, not redrawn on the CPU. A note can zoom back out to its fit. Undo needs a clean two-finger tap. Pencil double-tap borrows the eraser until lift. Add note and Add folder share one cell. Settings is grouped into ASCII, Paper, Pen, Import / Export, GitHub sync and Delete, and takes everything from the old "…" nav.
- One top bar spans every screen: back and settings stay, titles and search change in place, and screens change without waiting for the chrome. Entering a subfolder keeps the screen. Colour variations recolour in place when another swatch is tapped.
- The Windows app was rebuilt to match the iPad app behaviour for behaviour and also builds for Linux. It syncs with GitHub like the iPad, keeping its token in Credential Manager. Pen and mouse act as the Pencil and touch as the finger.
- The folder header is a single-row pill as tall as search and settings: the title first, its count small at the right end.
- Swiping the nav off its edge moves the whole stack: the secondary nav takes the main nav's place and the colour panel takes the secondary nav's; revealing reverses it.
- Size presets in the secondary nav show only their dot, without a px label.
- The size slide's track is a cone, thin at the start and widening to the end; its thickness at each point is the preview dot for that size.
- The secondary nav closes by scaling down as a capsule instead of shrinking into a circle first.
- Pen and marker size and colour groups collapse to their first two presets with a swipe towards their start; their + turns into an expand arrow, and a swipe back or a tap on the arrow restores them. Each group remembers its state across launches.
- Normal text has one size, fitted to the guide rows: its line height is the row gap (297 / 59 mm) and every baseline sits on a guide line, wrapped lines included. Text boxes snap to the rows; older blocks are drawn fitted and take the fitted size when they are next edited or moved. The font-size control is gone.
- While text is edited a ".md" button opens a style nav: bold, italic, underline, strikethrough, dashed underline, inline code, heading, bullet list and numbered list, each shown as selected for the selection or caret. The editor shows the styles while typing. Everything is stored in the block's Markdown (underlines as `<u>` tags), so styles sync with the text. Headings take whole rows.
- While text is edited a "code" button opens a language nav (JavaScript, C#, Java, Python, normal text). A selection on one line becomes an inline code span that shares the row with prose; a selection over several lines becomes a fenced code block. Both are syntax-highlighted (keywords, strings, numbers, comments) in colours from the tokens, and "normal text" removes the code formatting.
- On every folder level the folders are listed above the notes, also when the level has no notes.
- Dragging a tile keeps it under the finger at the point it was grabbed. The other tiles make room for the slot under the finger, and releasing puts the tile in that slot.
- Folder and note tiles can be dragged into a group of their kind, and cards of an open group can be dragged out into the grid, onto a folder or onto the back button.
- An open group closes on a tap on empty space and on a sideways swipe that starts outside it.
- No scroll indicators are shown anywhere in the app.
- Settings take the whole screen; their modules sit in two columns when there is room and in one column otherwise. Settings enter from the top and push the canvas and its top bar down; on leaving, the canvas pushes them back up. They move as one window: the modules have no animations of their own, and there is no backdrop, so the app's background shows behind them.
- The icon and colour sheet has a colour wheel and saved colours like the toolbar's colour group: + saves the current colour, holding a saved colour removes it.
- While the nav is carried it turns to the orientation of the edge it is nearest (vertical by the sides, horizontal by the top and bottom) before it is let go; its elements pop out quickly and back in once it has turned.
- The folder name at the top left shows only inside a folder. It enters and leaves like the search field and the nav: its elements pop in and out and the pill spreads and narrows.
- Each tool in the nav has its own colour: pen white, eraser red (with a ring-and-stroke icon), marker light purple, lasso yellow, text blue. In the text nav, `.md` is red-pink, code is indigo, and the T shows the selected text colour with its dot. There is no keyboard button.
- While the size slider is held for the pen, marker or eraser, a dot in the centre of the screen shows the true size at the current zoom.
- While the eraser is selected, a faint red triangle sits in each corner of the screen. The triangles slice in out of their corners when the eraser is selected and back into them when it is deselected.
- The nav can lie over the note's name; the name never pushes it aside.
- The nav turns only when it is carried against an edge: vertical at the left and right edges, horizontal at the top and bottom.
- Zooming while text is being edited moves smoothly through the whole range.
- Text is larger on its rows and stands a little above the ruled line instead of touching it.
- Code blocks indent like a code editor: Enter keeps the indent and adds a level after an open bracket (or a Python colon), a closing bracket and Backspace take one off, Tab runs to the next stop. The level is read from the block. The keyboard drops autocorrect and smart quotes inside code.
- Imported files are capped at 50 MB each, GitHub's own warning size and half its 100 MB limit. Assets sync through `assets/<sha256>` in the same commit as the first page that uses them, and every device fetches the assets its pages reference.
- Columns and rows can be removed again: the page menu splits each add row into add and an icon-only remove, which removes the cell under the hold point. The extent carries its own clock, `extent_updated`, so a removal survives sync.
- The hold menus have no container: only their rows, with dividers centred in their gap.
- Tapping a lasso selection opens a selection menu: Cut and Copy as icons on top, then Duplicate, Colour and Equal width. Paste sits at the top of the page menu and centres the clipboard on the hold point.
- Settings fill the screen: one container covers the whole window and the modules sit in a column 75% of its width.
- The writing font is a setting: any font family installed on the device, with Space Mono (the default), General Sans and the VAD/OS handwriting font ("My Handwriting") bundled first. The iPad can also add a font file. Code blocks and inline code are always Mono. The choice is per device and is not synced; the stored Markdown does not change.
- An imported PDF page fills its whole cell and behaves as the page itself: it cannot be selected or moved, and the grid and dividers draw over it.
- Hold menus no longer dim the page behind them.
- In code blocks, brackets close themselves, typing the closer steps over it, and Backspace between a pair removes both. On the iPad, Enter on a line of inline code turns it into a code block, and choosing a code language on an empty line opens one.
- Marker strokes never stack: all markers on a page are drawn as one layer, so where two cross the colour stays the same.
- The writing font is picked from a drop-down with a search field. The iPad drop-down also opens the system font picker, which lists fonts installed by profile or by font apps.
- GitHub sync sits under ASCII. Import and Export are modes of the View All view; Rename and Delete are in the note's hold menus.
- A View All button left of Back (on a note) opens the note as its grid of cells beside a strip of its pages. View all mode lets any cell be dragged onto another to swap their contents; Export and Import are the other two modes of the same view.
- Import and Export open a full-screen view of the note as its grid of cells. Export: the selected cells become the pages of the PDF, one A4 page per cell, in reading order (row by row) unless pages are carried to another order. Import: after choosing a PDF, the selected cells are where its pages go, page 1 in the first selected cell in reading order and so on; empty rows are offered below the note, and placing a page outside the current extent grows the note. Cells are selected by tapping, by dragging across them, or a whole row at once from its number.
- The Import and Export view shows the PDF's pages on the left, top to bottom, and the note's cells on the right. Every placed cell and strip page shows its page number as x/N at the bottom right. A page can be dragged to another cell (swapping with a page already there), and a held page from the strip can be dropped into a cell. An invert toggle among the top-right buttons decides whether white PDF pages are inverted on dark paper.
- Every colour wheel has a Copy colour button at its top right.
- The nav, the secondary nav and the colour wheel stay usable after any interrupted touch. A nav gesture that the system cancels (a sheet or file picker opening, the canvas taking the touch) now ends exactly like a released one.
- Whether an imported PDF page shows inverted is stored on the page element (`inverted`) and synced, so the iPad and the desktop always agree. A new import is inverted when its page is white and the importing device has dark paper. View All's Normal / Inverted sets it for every PDF page of the note (and for a PDF waiting to be imported); the page menu's Invert PDF / Original PDF flips the page under the finger.
- View All has a dashed + strip at the right of the grid that adds a column and one under it that adds a row.
- The iPad ignores a resting hand: a broad contact, any finger touch while the Pencil writes, and touches in the bottom and bottom-right rest area right after writing never zoom, pan, undo or open menus. The rest area learns where the hand actually lies.
- A long, nearly straight marker stroke (25 mm or more, staying within 12 % of its length of one line and not doubling back) lands as a straight line at the angle it was drawn. Curves, short strokes and scribbles keep their shape.
- Writing and erasing cost the same on a one-page note and on a note with many pages or PDFs: each stroke, erase or edit is written to disk once and redraws only the area it touched, and the canvas only draws what is on screen.
- The app's memory stays bounded however long it runs: caches for PDF pages, thumbnails, strokes and text have fixed budgets, are emptied when the system asks for memory and when their note closes, and the local change log keeps only the latest state of each changed thing.
- The note name on the canvas sits on a dark translucent backdrop that ends with the folder, name and date, not at the controls, and is always shown in full: it wraps to two lines and then gets smaller rather than being cut. A rename is saved when editing ends.
- Groups sync. Each group is its own file under `groups/`, its members carry its ID, and groups kept on a device before are moved into the repository on the next launch.
- Windows and Linux are on par with the iPad again: the styled `.md` editor and the code nav with syntax highlighting, text on the guide rows, collapsible preset groups, the stack-wide edge hide, the cone slider, the capsule leave, settings module pops, the single-row folder head that shows only inside a folder, tool colours and the size preview dot, nav turning at edges while carried, the slot-under-the-pointer drag with groups, and the colour wheel in the icon and colour sheet.
- Inside a folder every note is a 1×1 tile showing its first page, with its size as a caption. The name wraps to two lines and then gets smaller, and never leaves the tile. Previews are cached and drawn without holding up the screen, so a folder of 30 or more notes opens smoothly.
- View All lists the note's PDF pages in a column on the far left, grouped by file under its name and a colour of its own. A green dot marks a page used in the note, a red one a page that is not. Tap a PDF page, then a note page, to put it there: it moves if it was already in the note, and replaces any other PDF page on that note page, leaving ink and text alone; one undo reverts it. Each file's header inverts all its pages at once.
- View All is a full-screen overlay over the note, not a panel. The PDF column (or the page strip in Export and Import) and the page canvas each scroll on their own; the canvas pans both ways, past the note in every direction, and opens on page 1, 1. Every page of the note shows as a page, blank or not. Select (the tick) marks filled pages and the trash clears the chosen ones in one undo step; holding a page and dragging it swaps it with another. The modes are separate buttons at the top right, each mutating on its own.
- View All works the same in portrait and landscape. Its top-right controls are the canvas top bar's own buttons, changed in place (see the iPad bullet below). In Import, the page that the next tap will place (the one tapped in the strip, or the next unplaced page) has a faint white outline. The backdrop shows the ASCII layer and slides in from the left and out to the right. Each page added to the Export strip slides in.
- View All (iPad): the backdrop is fully opaque, with the ASCII layer on it. A drag that starts on a page pans the canvas; a hold and then a drag still carries the page. The pages are one continuous grid: a + cell sits only beside an existing page (a column of them on the right, a row of them below, none in the corner), and tapping one adds that column or row in place, with the new pages popping in, while View All stays open. View All draws no buttons of its own: the canvas top bar stays above it and its buttons change in place with the rotate pop. View all becomes Import, Back becomes Export and Settings becomes Back. The active mode's button takes the count and sends; there is no View all button. Buttons that View All needs beyond these (the tick and the trash in View, invert in Import and Export) appear as new buttons of the same kind to the left of them. The note's title stays while View All is open. In Import or Export, back ends that mode and returns to View, dropping the chosen file or selection; in View it closes View All. The window enters from the left and pushes the canvas off to the right; on leaving, the canvas pushes it back out to the left. The columns, the grid and the labels move with the window, without animating on their own. The window has no ground of its own: the app's background stays still behind both. Page outlines and axis numbers are brighter. The canvas pans left by at least a full screen width past page 1, 1.
- The main toolbar moves like the iPad's own tool palette. A small grabber on the side facing the screen picks it up at once (at the bottom of a bar along the top edge); the secondary nav and panels step out of the way while it moves. Dragged far or flung, it shrinks evenly into a small circle, which then gathers under the finger and trails it, can be thrown, and bounces softly off the screen edges. The circle shows only the grabber mark, not the current tool. The toolbar rests only against an edge or in a corner: within the outer 10% of the screen it opens towards that edge while still held, a drop anywhere else settles at the nearest edge, and a throw opens early as it heads into the outer 20%. Dropped or thrown into a corner it stays there as a circle; a tap opens it again along the nearer edge. Brought to an edge it first turns to suit that edge, then opens against it with a springy overshoot, and the secondary nav comes back beside it. Its place, including a parked corner, is remembered.
- Panning and zooming a dense page moves the ink as one picture and redraws it sharp once the camera stops, so handwriting never makes the canvas stutter. Settings push the whole screen, top bar included, fully out of view. The top bar reads Settings first and Back last. In View All the grid can be pinched out to see the whole note, empty pages can be carried too, and each + cell keeps a red − strip on its inner fifth that removes the last column or row (a filled one is marked in red first and needs a second tap).
