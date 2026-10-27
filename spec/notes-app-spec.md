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
- Expanding doubles one axis at a time: 1×1 → 2×1 → 2×2 → 4×2, and so on.
- Expansion only changes the visible extent and the cell boundary lines. No stored element moves.
- Expansion is triggered by a button: "add column" or "add row" in the page menu doubles that axis.
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
  "elements": []
}
```

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
notebooks/<notebook id>/notebook.json      { schema_version, id, title, updated, device, deleted, color?, icon?, parent? }
notebooks/<notebook id>/pages/<page id>.json
assets/<sha256>
```

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
- **Page metadata** (extent, title): latest `updated` wins.

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
- GitHub rejects single files over 100 MB, and large files slow the repo down. v1 caps imports at a size limit (to be decided). Git LFS is the fallback for anything larger.

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
- Extent in A4 cells with doubling expansion.
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
9. **Import size cap:** what is the maximum file size per imported PDF or image?
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
