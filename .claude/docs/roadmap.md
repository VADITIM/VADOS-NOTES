# Roadmap

Phases follow `spec/notes-app-spec.md` section 9.

- [x] Phase 0: repo structure, spec, `shared/tokens.json`
- [x] Phase 1: schema, journal, merge, push protocol, mock backend, 44 tests
- [~] Phase 2: iPad app written and reworked (finger pans, lasso, groups, tile flight); first device build pending
- [x] Phase 3: Windows and Linux app (Tauri), rebuilt to match the iPad behaviour for behaviour; built by the `windows` and `linux` jobs
- [~] Phase 4: extent doubling implemented on iPad (menu: add column / add row)
- [~] Phase 4b: PDF import (new notes and Settings → Import); images pending
- [x] Phase 5: text blocks on iPad and Windows
- [x] Phase 6: flush policy, lifecycle flush, offline queue, periodic pull on iPad, Windows and Linux
- [~] Phase 7: PDF export (vector on iPad, raster on Windows and Linux)
- [ ] Phase 8: polish, VAD/OS integration, tombstone compaction
