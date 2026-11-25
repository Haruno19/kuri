# 0027. Releases are a disk image made by one script

**Decided.** A release is `Kuri-<version>.dmg`, made by `Release/make-dmg.sh` with Apple's own tools only: `xcodebuild` builds the app in Release for Apple silicon, `hdiutil` makes the image, Finder (through AppleScript) lays out its window, and `codesign`, `notarytool` and `stapler` sign and notarize it when a Developer ID is given. The window shows the app, an arrow and a link to Applications on a still frame of the meadow, drawn by `Release/Background.swift` from the app's own `Meadow.swift`, so the background follows the meadow as it changes.

- **Ad-hoc signed until there's a Developer ID.** Without one, the app keeps Xcode's ad-hoc signature (hardened runtime and the virtualization entitlement still apply), and people allow it once in Privacy & Security; the README says how. Setting `KURI_SIGN_IDENTITY` and `KURI_NOTARY_PROFILE` turns on signing and notarization with no other change.
- **Apple silicon only.** The sandbox's VMs and Apple's on-device model need it; an Intel slice would double the download for an app that can't do its main work there.
- **A still background.** Finder only shows still images behind a window, so the meadow is one frame, at 1x and 2x in one TIFF.

**Why.** The dependency rule (Apple first, never small third-party tools) rules out the usual `create-dmg` scripts and `.DS_Store` writers; Finder itself is the only Apple way to store a window's layout. Drawing the background from the app's code keeps one meadow instead of a picture of it that drifts.

**Cost.** The script drives Finder, so it needs permission to control it the first time, opens a window for a few seconds, and has to run in a logged-in session (not headless CI). Until releases are notarized, the first launch takes an extra step.
