# Roadmap

Phases follow `spec/notes-app-spec.md` section 9.

- [x] Phase 0: repo structure, spec, `shared/tokens.json`
- [x] Phase 1: schema, journal, merge, push protocol, mock backend, 44 tests
- [~] Phase 2: iPad app written (canvas, journal round trip, notebooks, pages, text, menus, sync wiring); first device build pending
- [x] Phase 3: Windows app (Tauri): library, notebook and page screens, canvas renderer, menus, pop bar; built by the `windows` workflow
- [~] Phase 4: extent doubling implemented on iPad (menu: add column / add row)
- [ ] Phase 4b: PDF and image import
- [x] Phase 5: text blocks on iPad and Windows
- [~] Phase 6: flush policy, lifecycle flush, offline queue, periodic pull on iPad; Windows pending
- [ ] Phase 7: PDF export
- [ ] Phase 8: polish, VAD/OS integration, tombstone compaction
