# Decisions

Reasons that would otherwise be comments. The spec's section 11 is the product-level log; this file is the code-level one.

## Core (`ios/NotesCore`)

- **Journal replay merges, it does not overwrite.** State is the synced snapshot plus every journal entry applied through the merge rules, so a newer remote edit still beats an older local one after a pull.
- **Snapshot is the last remote state, not the last local one.** A pull replaces snapshot files with remote bytes; local work lives only in the journal until a push lands.
- **Entries are removed by sequence, not "through" a sequence.** Entries for blocked pages (corrupt or newer schema on the remote) stay in the journal while the rest are removed.
- **A push only includes entries that existed when the files were built.** Building the files and capturing the sequences happen without a suspension point, so changes made during the network calls stay in the journal for the next flush.
- **409 and 422 both mean "branch moved".** GitHub answers a non-fast-forward ref update with 422; the spec's wording said 409.
- **An empty repository is started through the contents API.** The Git Data API refuses blobs on a repository with no commits, so the first commit is a README written with `PUT contents`.
- **Extent merges as the union of both axes.** Extent only ever grows, so taking the larger value per axis needs no timestamp and cannot lose an expansion.
- **Equal timestamps break ties by device name.** Keeps the element merge commutative.
- **Timestamps are rounded to milliseconds when created.** They round-trip through the file format exactly, so a decoded page equals the page that was written.
- **Points are rounded to 0.01 mm and thinned below 0.15 mm.** Same bytes on every platform, and Pencil's 240 Hz samples do not bloat the files.
- **Tool opacity is not stored per stroke.** It comes from `shared/tokens.json` by tool, so marker translucency is one definition for both renderers.

## iPad app (`ios/VadosNotes`)

- **Custom canvas, no PencilKit.** Points are the stored truth and are drawn as constant-width paths; nothing to strip out of PencilKit's pressure model.
- **Once a Pencil touch is seen, one finger pans instead of drawing.** Palm rejection without a setting. Before any Pencil touch, a finger draws.
- **A finger held still for 450 ms opens the page menu**, and the stroke it started is discarded. The Pencil never opens menus.
- **The menu opens above the finger**, so lifting without moving selects nothing; sliding onto a slot and lifting selects it.
- **Destructive slots arm on the first tap and act on the second** (V/AS confirm pattern, inside the menu).
- **Undo of an erase re-creates the stroke under a new ID.** A tombstone always wins a merge, so reviving the old ID would be undone by the next sync.
- **A new text block is journaled only once it has a character.** Abandoned empty blocks never reach the repo.
- **No blur, no glass, no shadows.** The spec overrides the Gallery's glass pill: the pop bar is a flat `panel_solid` capsule with a hairline.
- **One accent (`#FFDD1B`) app-wide.** Green, blue, red, grey and amber are taken by the spec's semantic roles, so the accent had to be a colour none of them use.
- **Swift 5 language mode in the app target.** UIKit timer and gesture callbacks would need annotations everywhere under Swift 6 strict concurrency for no gain in a single-window app.

## Windows app (`windows/`)

- **Plain ES modules, no bundler.** The frontend runs as-is in WebView2 and in any browser, so the UI can be previewed without Rust.
- **Tokens come from Rust.** `shared/tokens.json` is compiled into the binary with `include_str!` and handed to the frontend by the `tokens` command, so there is still one definition.
- **Squircles are drawn as SVG paths**, generated with the same superellipse as `Squircle.swift` (exponent 5, 12 steps per corner, extent 1.8 × radius). CSS `border-radius` would give a different corner.
- **Text is laid out once at a reference scale** (10 px per mm) and drawn at the current zoom, so line breaks do not shift while zooming.
- **Right-click opens the same menu a hold opens.** Holding still still works; right-click is the Windows habit and changes no slot.
- **Mouse draws like the Pencil; touch follows the finger rules.** Middle-drag, Space+drag and the wheel pan, Ctrl+wheel zooms.
- **The camera is not refitted on window resize.** The iPad refits on rotation; on Windows resizes are frequent and refitting would throw away the zoom.
- **Pages are written straight to files in the repository layout.** No journal yet; that arrives with Windows sync (phase 6).

### Nav, tools and paper (Windows first, iPad to follow)

- **One nav for the whole app**, the way VADOS Gallery's `BottomBar.qml` works. Each screen hands it a kind and its buttons. When the kind changes, the old buttons pop away with `back_in` over the first `state`, the new ones pop in with `back_out` over the second, and the pill's size follows across both with `power_three_in_out`.
- **The selected tool's wash slides** like Gallery's `SectionBar.qml`. The edge in the direction of travel goes first, and the trailing edge follows `nav_trail` (60 ms) later, both over `nav_slide` with `power_two_out`.
- **Holding the nav for `nav_carry_hold` (1 s) carries it.** Touch and pen pointers are implicitly captured by the pressed button; moving the capture to the nav makes the button fire a bubbling `lostpointercapture`, which must not end the carry. It retracts into a circle under the finger and follows it. On release it turns vertical if it is nearer a side edge than the top or bottom, otherwise horizontal, and expands there. The centre is stored as a share of the window, so it keeps its place on resize.
- **Tapping the selected tool opens its second nav** beside the first, on the side that faces into the window. Pen and marker get a size slider, colour presets (as many as wanted: + saves the current colour, hold or right-click arms a preset, a second tap removes it) and a colour wheel with a hex field. The eraser gets a size slider and the two modes.
- **One pen (Kugelschreiber).** The pencil left the nav; strokes made with it still render, and its tokens stay so iPad files keep drawing the same.
- **Precise erasing replaces each touched stroke with its remaining pieces**, so files stay plain strokes. The eraser sweeps a capsule from the previous pointer sample to the current one, so a fast swipe leaves no islands. Each stroke segment is cut exactly where it leaves the capsule (radius = eraser radius plus half the stroke width, so a cut end's round cap stops at the eraser's edge). Distance to a capsule is convex along a segment, so ternary search finds the closest point and bisection finds the two boundaries. Untouched parts keep their original points. The whole drag is one undo step: tombstones for the originals and new elements for the pieces.
- **Ink is smoothed, then stored.** Raw samples are resampled every `ink.sample_spacing_points` screen points, run through a Gaussian (sigma `ink.smoothing_points`, the window shrinking symmetrically at the ends so the endpoints stay put and the tip follows the pen), and simplified with Douglas-Peucker at `ink.simplify_points`. All three are in screen points, so writing zoomed in keeps finer detail. The live stroke is the same function on the same samples, so what is drawn is what is saved. Strokes render as centripetal Catmull-Rom splines through the stored points.
- **Holding still while drawing straightens the stroke.** If the pointer stays within `ink.straighten_tolerance_points` for `stroke_straighten_hold` (1 s), the stroke eases into a straight line over `stroke_straighten_snap`; moving on drags its end until release.
- **Pen and marker keep size presets** next to the slider (`width_presets` in tokens, + saves the current size, removal as for colours). The second nav and the colour panel centre on the main nav along its axis.
- **Paper is dark by default; white is a toggle** in the top bar. Neutral inks (chroma at most `neutral_ink_chroma`) are stored as they read on white paper and are inverted on dark paper. So black pen writes white on black, the file still says black, and the iPad shows it correctly.
- **Two fingers double-tapped undo; three fingers redo.** A tap counts only if the fingers stay within 14 px and lift within 320 ms; the second tap must come within 420 ms.
- **Every Windows build on `master` is published as a GitHub release** (`windows-build-N`, marked latest), so the app is a direct download.
