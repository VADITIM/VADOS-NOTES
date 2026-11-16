# VAD/OS Notes

This project is built on V/AS (VAD/OS APPLICATION SYSTEMS), base register. Read `.claude/skills/vas/SKILL.md`.

- Spec: `spec/notes-app-spec.md` is the reference. Decisions taken while building are logged in its section 11 and in `.claude/docs/decisions.md`.
- `ios/NotesCore` is the platform-free core (schema, journal, merge, sync). It builds and tests with `swift test` on macOS, Linux and Windows.
- `ios/VadosNotes` is the SwiftUI iPad app. Generate the Xcode project with `xcodegen` inside `ios/`.
- `windows/` is the Tauri app for Windows and Linux, a behaviour-for-behaviour port of the iPad app. `windows/src` is plain ES modules with no build step; `npx tauri build` inside `windows/` makes the installers.
- `shared/tokens.json` is the one definition of colours, slots and motion. Both clients read it.
- Version: `VERSION` holds the current version (1.4.0). Before every commit and push, ask the user Major, Minor or Patch, bump `VERSION` and every manifest (`ios/project.yml` MARKETING_VERSION, `windows/package.json`, `windows/src-tauri/tauri.conf.json`, `windows/src-tauri/Cargo.toml`), and add the entry to `.claude/changelogs/DD-MM-YY.md`.
- Code carries no comments and no abbreviated names (V/AS module 09). Reasons go to `.claude/docs/`.
