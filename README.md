# FinderBreadcrumbs

FinderBreadcrumbs is a native macOS prototype that adds a small companion path bar just under the frontmost Finder window. It is designed to feel closer to the Windows Explorer address bar workflow without trying to modify Finder's built-in chrome.

## What it does

- Tracks the frontmost Finder window and snaps a slim overlay bar beneath it.
- Shows the current path in `text` mode by default, with a config option for `breadcrumb`.
- Clicks into edit mode or focuses edit mode with `Option+Command+L` while Finder is frontmost.
- Navigates the current Finder window to the typed path when you press `Return`.
- Resolves symlinks before navigation.
- Attempts unambiguous filesystem autocomplete when you press `Tab`.

## Current architecture

- `FinderWindowTracker` uses Accessibility APIs to find the focused Finder window and its frame.
- `OverlayWindowController` hosts a floating non-activating panel that follows the Finder window.
- `FinderAutomationService` is intentionally isolated because Finder path read/navigation currently relies on Apple Events as a practical fallback.

## Important limitation

The companion window attachment is App Store-friendly in spirit, but the current-path read and navigation layer still uses Finder automation. That is the right prototype move, but it is the main area to reevaluate for App Store submission.

## Running

1. Open [FinderBreadcrumbs.xcodeproj](/Users/orlando/Documents/BreadCrumbs/FinderBreadcrumbs.xcodeproj).
2. Build and run the `FinderBreadcrumbs` target.
3. Grant Accessibility permission when prompted.
4. Grant Finder automation permission if macOS asks for it.

The app writes its config to:

`~/Library/Application Support/FinderBreadcrumbs/config.json`

You can start from the sample file at [Config/default-config.json](/Users/orlando/Documents/BreadCrumbs/Config/default-config.json).

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
- Add a small preferences UI once the config surface settles.
- Add launch-at-login support through a proper helper target if we decide to keep that feature for distribution.
