# VAD/OS Notes — Windows

Tauri 2 app. Same screens, menus, pop bar, motion and page renderer as the iPad app, built from the same `shared/tokens.json`.

## Get the app without building

Push to GitHub. The `windows` workflow builds on a Windows runner and uploads two artifacts:

- `VadosNotes-windows-installer`: the setup `.exe` (NSIS) and an `.msi`.
- `VadosNotes-windows-portable`: `vados-notes.exe`, runs without installing.

Windows SmartScreen warns about an unsigned app the first time: **More info → Run anyway**.

## Build locally

Needs [Rust](https://rustup.rs), Node 22, and the Visual Studio C++ build tools. WebView2 ships with Windows 10 and 11.

```bash
cd windows
npm install
npx tauri dev      # run
npx tauri build    # installer in src-tauri/target/release/bundle
```

## Preview in a browser

The frontend is plain ES modules with no build step. From the repository root:

```bash
python -m http.server 8765
```

Open `http://localhost:8765/windows/src/index.html`. In a browser, notes are kept in `localStorage` instead of files.

## Using it

- Mouse or pen draws. Touch draws until a pen is seen, then one finger pans. Two fingers pan and zoom.
- Wheel pans, Shift+wheel pans sideways, Ctrl+wheel (or touchpad pinch) zooms. Middle-drag or Space+drag pans.
- Right-click the page, or hold a finger still on it, to open the page menu. Right-click or hold a pen, pencil or marker button to pick its colour.
- Text tool: click empty paper to type, click a block to edit it, drag a block to move it. Esc finishes.
- Ctrl+Z undoes, Ctrl+Shift+Z or Ctrl+Y redoes.
- Delete actions arm on the first click and act on the second.

## Storage

Pages are written in the repository layout (`notebooks/<id>/notebook.json`, `notebooks/<id>/pages/<id>.json`) with the same byte format as the iPad, under `%APPDATA%\com.vaditim.notes\notes`.
