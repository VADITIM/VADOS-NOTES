# VAD/OS Notes — Windows and Linux

Tauri 2 app. It mirrors the iPad app screen for screen and behaviour for behaviour, built from the same `shared/tokens.json` and the same ASCII art (`ios/VadosNotes/Resources/background.txt`).

## Get the app without building

Every push to `master` is built and published as the latest release: **https://github.com/VADITIM/VADOS-NOTES/releases/latest**

- `VadosNotes-portable.exe`: runs without installing.
- `VADOS Notes_*_x64-setup.exe`: installer. An `.msi` sits beside it.
- `*.AppImage` and `*.deb`: Linux.

Windows SmartScreen warns about an unsigned app the first time: **More info → Run anyway**.

## Build locally

Needs [Rust](https://rustup.rs), Node 22, and the Visual Studio C++ build tools on Windows (WebView2 ships with Windows 10 and 11). On Linux: `libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev patchelf libdbus-1-dev libssl-dev`.

```bash
cd windows
npm install
npx tauri dev      # run
npx tauri build    # installers in src-tauri/target/release/bundle, the exe in src-tauri/target/release
```

## Preview in a browser

The frontend is plain ES modules with no build step. From the repository root:

```bash
python -m http.server 8765
```

Open `http://localhost:8765/windows/src/index.html`. In a browser, notes are kept in `localStorage` instead of files.

## Input

The iPad's input rules map onto Windows like this:

- **Pen and mouse** are the Pencil: they draw, erase, start the lasso and add text. A pen's eraser end erases while it touches and gives the tool back when lifted.
- **Touch** is the finger: one finger pans and glides, a held finger opens the page menu, two fingers pan and pinch, a clean two-finger tap undoes and a clean three-finger tap redoes. With a selection, one finger moves it and pinching on it scales it.
- **Right-click** opens the menu a hold opens. The wheel pans, Shift+wheel pans sideways, Ctrl+wheel (or a touchpad pinch) zooms, middle-drag or Space+drag pans.
- **Keys**: Ctrl+Z undoes, Ctrl+Shift+Z or Ctrl+Y redoes, Ctrl+F searches, Esc clears the search or finishes text.

## Storage and sync

Pages are written in the repository layout (`notebooks/<id>/notebook.json`, `notebooks/<id>/pages/<id>.json`) with the same byte format as the iPad, under `%APPDATA%\com.vaditim.notes\notes` (Linux: `~/.local/share/com.vaditim.notes/notes`). The last synced remote state is kept beside it in `synced/`.

GitHub sync is set up in Settings → GitHub sync with owner, repository, branch and a fine-grained token (contents read and write). The token is kept in Windows Credential Manager (the Secret Service on Linux), never in a file.
