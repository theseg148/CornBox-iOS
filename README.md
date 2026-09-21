# CornBox for iPhone

This is the iOS wrapper for the supplied CornBox `app.html`.

## What changed for iPhone

- The CornBox HTML/CSS/JS UI is still the actual interface.
- It runs inside an iOS `WKWebView`.
- **Open my videos** and the **+** button open a native choice between **Photos** and **Files**.
- Imported photos/videos are copied into CornBox's private app storage, so they remain available after relaunching the app.
- Likes, comments, albums and auto-scroll continue to use the existing CornBox web UI/storage.
- The Windows `CornBox.exe` is not used by the iPhone app.

## Free build from Windows

You do not need a Mac.

1. Create a new GitHub repository.
2. Upload **the contents of this folder** to the repository. Make sure `.github/workflows/build-ipa.yml` is included.
3. Open the repository's **Actions** tab.
4. Open **Build CornBox IPA** and choose **Run workflow**. A push to `main` also starts a build automatically.
5. When the build finishes, download the artifact named **CornBox-unsigned-IPA**.
6. Extract the downloaded GitHub artifact ZIP. Inside is `CornBox-unsigned.ipa`.
7. On Windows, use **AltStore Classic / AltServer** (or another IPA signer you trust) to sign/install that IPA onto your iPhone with your Apple ID.

With a free Apple ID, sideloaded apps normally need to be refreshed every 7 days.

## Project layout

- `CornBox/Resources/app.html` — the CornBox UI.
- `CornBox/Sources/CornBoxApp.swift` — iOS wrapper + Photos/Files importer.
- `project.yml` — XcodeGen project definition.
- `.github/workflows/build-ipa.yml` — free cloud-Mac IPA build.

## Editing CornBox later

Most UI changes only require editing `CornBox/Resources/app.html`, then pushing the change to GitHub. The workflow builds a new IPA automatically.

## Sharing note

The old Windows README says `CornBox.exe` serves the feed to other devices on the same Wi-Fi. That server behavior is a separate Windows feature and is **not** included in this first iPhone wrapper. This IPA is currently a local personal CornBox library on the iPhone.
