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
