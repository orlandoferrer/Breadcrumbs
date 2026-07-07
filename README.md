# FinderBreadcrumbs

FinderBreadcrumbs is a native macOS prototype that adds a small companion path bar just under the frontmost Finder window. It is designed to feel closer to the Windows Explorer address bar workflow without trying to modify Finder's built-in chrome.

## What it does

- Tracks the frontmost Finder window and snaps a slim overlay bar beneath it.
- Shows the current path in `text` mode by default, with a config option for `breadcrumb`.
- Clicks into edit mode or focuses edit mode with `Option+Command+L` while Finder is frontmost.
- Navigates the current Finder window to the typed path when you press `Return`.
- Resolves symlinks before navigation.
- Attempts unambiguous filesystem autocomplete when you press `Tab`.
- Hides the overlay while the Finder window is being moved or resized, then restores it after the window settles.
- Runs as a menu-bar app with Settings, Welcome & Permissions, and Quit Breadcrumbs menu items.

## Current architecture

- `FinderWindowTracker` uses CoreGraphics window information for the frontmost Finder window and Accessibility observers for focused-window, move, and resize notifications when permission is available.
- `OverlayWindowController` hosts a floating non-activating panel that follows the Finder window.
- `FinderAutomationService` is intentionally isolated because Finder path read/navigation currently relies on Apple Events.
- `StatusMenuController` owns the menu-bar item.
- `WelcomeWindowController` shows permission status and links/actions for Finder automation and Accessibility.
- `SettingsWindowController` manages Enable at login, Keyboard shortcut, and Text display.

## Permissions

Breadcrumbs needs two macOS permissions for the full experience:

- **Finder automation** lets the app read the folder shown in Finder and navigate Finder windows to typed paths.
- **Accessibility** lets the app track Finder's active window and follow move/resize changes more smoothly.

The app shows a **Welcome & Permissions** window on first launch, and again on launch if required permissions are still missing. The same window can be reopened from the menu-bar item.

The Finder automation request is triggered from the welcome window's **Request Permission** button. Accessibility is granted through System Settings, opened from the welcome window.

## Important limitation

The companion window attachment is App Store-friendly in spirit, but the current-path read and navigation layer still uses Finder automation, and the smoother window tracking uses Accessibility. See [APP_STORE_COMPLIANCE.md](APP_STORE_COMPLIANCE.md) for the current App Store assessment and possible distribution paths.

## Running

1. Open [FinderBreadcrumbs.xcodeproj](FinderBreadcrumbs.xcodeproj).
2. Build and run the `FinderBreadcrumbs` target.
3. Use the menu-bar item to open **Welcome & Permissions** if it is not already visible.
4. Grant Finder automation and Accessibility permissions from that window.

The app writes its config to:

`~/Library/Application Support/FinderBreadcrumbs/config.json`

You can start from the sample file at [Config/default-config.json](Config/default-config.json).

Most user-facing settings are available from the menu-bar **Settings** window:

- Enable at login
- Keyboard shortcut
- Text display: Plain Text Path or Breadcrumb

The shortcut can be configured with a readable string:

```json
"shortcut": "cmd+option+l"
```

Supported modifiers are `cmd`, `option`, `shift`, and `control`. Common keys
include letters, numbers, `space`, `tab`, `return`, `escape`, `delete`, and
arrow keys like `left` or `right`. The older numeric `{ "keyCode": ..., "modifiers": ... }`
format still works for existing configs.

To inspect Finder child-window behavior, temporarily enable:

```json
"debugLogFinderWindowDiagnostics": true
```

Then reproduce the issue and look for `FinderBreadcrumbs Finder window diagnostics`
messages in the Xcode console. The logs include CoreGraphics window data,
Accessibility role/subrole/title/document/frame data, and the Finder automation
state so child windows can be classified from observed behavior.

To bootstrap that config on a new Mac, run:

```bash
./setup.sh
```

It will copy the checked-in default config into Application Support and leave an
existing live config untouched unless you pass `--force`.

## Next likely steps

- Replace or reduce Finder automation dependencies where possible.
- Decide whether Developer ID distribution is the right path, or whether an App Store build should remove/replace the blocked behaviors listed in [APP_STORE_COMPLIANCE.md](APP_STORE_COMPLIANCE.md).
- Add broader regression coverage around Finder permission interruptions, network/external drives, and child-window tracking.
