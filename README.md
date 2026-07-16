# FinderBreadcrumbs

FinderBreadcrumbs is a native macOS prototype that adds a small companion path bar just under the frontmost Finder window. It is designed to feel closer to the Windows Explorer address bar workflow without trying to modify Finder's built-in chrome.

## What it does

- Tracks the frontmost Finder window and attaches a slim companion bar directly beneath it.
- Shows the current path in `text` mode by default, with a config option for `breadcrumb`.
- Clicks into edit mode or focuses edit mode with `Option+Command+L` while Finder is frontmost. The configurable global shortcut is registered only while Finder is active, so it does not block matching shortcuts in other apps.
- Navigates the current Finder window to the typed path when you press `Return`.
- Resolves symlinks before navigation.
- Attempts unambiguous filesystem autocomplete when you press `Tab`.
- Hides the overlay while the Finder window is being moved or resized, then restores it after the window settles.
- Hides the overlay while Finder Quick Look is open when Accessibility permission is available.
- Runs as a menu-bar app with Settings, Welcome & Permissions, and Quit Breadcrumbs menu items.

## Current architecture

- `FinderWindowTracker` uses CoreGraphics window information for the frontmost Finder window and Accessibility observers for focused-window, move, and resize notifications when permission is available.
- `OverlayWindowController` hosts a focusable borderless panel that follows the Finder window and accepts keyboard input in edit mode.
- `FinderAutomationService` is intentionally isolated because Finder path read/navigation currently relies on Apple Events.
- `StatusMenuController` owns the menu-bar item.
- `WelcomeWindowController` shows permission status and links/actions for Finder automation and Accessibility.
- `SettingsWindowController` manages Enable at login, Keyboard shortcut, and Text display.

For a beginner-friendly tour of the Swift code, data flow, macOS APIs, and
concurrency model, read [CODE_WALKTHROUGH.md](CODE_WALKTHROUGH.md).

## Permissions

Breadcrumbs needs two macOS permissions for the full experience:

- **Finder automation** lets the app read the folder shown in Finder and navigate Finder windows to typed paths.
- **Accessibility** lets the app track Finder's active window and follow move/resize changes more smoothly. It also lets the app detect Finder Quick Look so the bar can hide during previews.

The app shows a **Welcome & Permissions** window on first launch, and again on launch if permissions are still missing. The same window can be reopened from the menu-bar item.

Finder automation is required for path reading and navigation. Without Accessibility, the app runs in **Limited** mode using CoreGraphics and polling: basic tracking still works, but motion updates are less immediate and Quick Look cannot be detected reliably.

The Finder automation request is triggered from the welcome window's **Request Permission** button. Accessibility is granted through System Settings, opened from the welcome window.

## Important limitation

The companion window attachment is App Store-friendly in spirit, but the current-path read and navigation layer still uses Finder automation, and the smoother window tracking uses Accessibility. See [APP_STORE_COMPLIANCE.md](APP_STORE_COMPLIANCE.md) for the current App Store assessment and possible distribution paths.

## Running

1. Open [FinderBreadcrumbs.xcodeproj](FinderBreadcrumbs.xcodeproj).
2. Build and run the `FinderBreadcrumbs` target.
3. Use the menu-bar item to open **Welcome & Permissions** if it is not already visible.
4. Grant Finder automation. Grant Accessibility as well for smoother tracking and Quick Look detection.

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

Polling intervals from the config must be positive, finite numbers. Invalid
values fall back to safe defaults rather than creating a continuously firing
timer. Config changes made directly on disk take effect after relaunching the app.

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

## Development checks

Run the typecheck and lightweight regression suite with:

```bash
./check.sh
```

The suite covers editing focus and window targeting, fresh-snapshot hotkey
coalescing, readable shortcut config, hotkey registration lifecycle, Finder
polling/reentrancy, resize hiding, config sanitization, and Quick Look
classification. It uses mocks and does not require Finder permissions.

## TODO: Potential bugs and unspecified behavior

These items were identified during a code audit. They are candidates for
reproduction, design decisions, and regression coverage rather than confirmed
bugs in every macOS configuration.

### Potential bugs

- [x] Prevent the edit hotkey from using stale Finder state immediately after
  switching windows by waiting for a fresh, window-ID-matched snapshot before
  entering edit mode.
- [ ] Move path completion, filesystem validation, symlink resolution, and
  Finder navigation off the main actor where possible so slow network or
  external volumes cannot freeze the UI.
- [ ] Keep the breadcrumb bar within the active screen's visible frame when a
  Finder window is close to the screen edge or Dock, and avoid making the bar
  wider than a narrow Finder window.
- [ ] Distinguish an active resize from late resize notifications so the bar
  does not begin another hide/show cycle after it has already settled.
- [ ] Clamp polling intervals to sensible minimum values; currently any finite
  positive value is accepted, including values small enough to cause excessive
  CPU use.
- [ ] Make Settings saves transactional, or roll back Enable at login and hotkey
  changes when hotkey registration or config persistence fails.

### Behavior to define

- [ ] Decide whether relative paths should resolve from the active Finder folder,
  the filesystem root, or be rejected as invalid input.
- [ ] Decide whether manually configured shortcuts must include a modifier, as
  the Settings UI requires, or whether plain-key global shortcuts are supported.
- [ ] Confirm whether Quick Look in another Finder window or macOS Space should
  hide the bar attached to the currently visible Finder window.

## Next likely steps

- Replace or reduce Finder automation dependencies where possible.
- Decide whether Developer ID distribution is the right path, or whether an App Store build should remove/replace the blocked behaviors listed in [APP_STORE_COMPLIANCE.md](APP_STORE_COMPLIANCE.md).
- Add broader regression coverage around Finder permission interruptions, network/external drives, and child-window tracking.
