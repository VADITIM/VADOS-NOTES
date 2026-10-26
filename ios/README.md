# VAD/OS Notes — iPad

## Build

Needs a Mac with Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
cd ios && xcodegen generate && open VadosNotes.xcodeproj
```

Pick your team under Signing & Capabilities, choose your iPad, run.

Without a Mac: push the repository to GitHub; the `ios` workflow tests the core on Linux and builds the app for the iPad simulator on macOS.

## Core tests

`NotesCore` has no Apple dependency.

```bash
cd ios/NotesCore && swift test
```

On Windows this needs the Swift toolchain and the Visual Studio developer environment (`vcvars64.bat`) in the same shell.

## Sync setup

1. Create a private GitHub repository for notes (empty is fine).
2. Create a fine-grained personal access token with access to only that repository and **Contents: read and write**.
3. In the app, tap the sync badge, enter owner, repository, branch (`main`) and the token. The token goes to the iOS Keychain.

## Using it

- Pencil draws. Before a Pencil is used, a finger draws too; after, one finger pans. Two fingers pan and zoom.
- Hold a finger still on the page to open the page menu. Slide onto a slot and lift, or tap a slot.
- Hold a pen, pencil or marker button to pick its colour.
- Text tool: tap empty paper to type, tap a block to edit it, drag a block to move it.
- Delete actions arm on the first tap and act on the second.
