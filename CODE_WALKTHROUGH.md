# FinderBreadcrumbs Code Walkthrough

This guide explains how the app works and highlights the Swift and macOS ideas
used by the implementation. Read it once from top to bottom, then follow the
links into the source files.

## 1. The Mental Model

FinderBreadcrumbs is a menu-bar app with a separate borderless window. It does
not inject code into Finder or modify Finder's own views. Instead, it repeatedly
answers three questions:

1. Is Finder the active application?
2. Where is Finder's front window, and which folder does its active tab show?
3. Should the companion bar be shown, hidden, or placed into edit mode?

The main data flow is:

```text
Finder
  |-- Core Graphics: window frame and window number
  |-- Apple Events: active folder and Finder window ID
  `-- Accessibility: move/resize/focus notifications and Quick Look
                    |
                    v
           FinderWindowTracker
                    |
        FinderWindowTrackerUpdate
                    |
                    v
              AppCoordinator
               /          \
              v            v
     PathBarViewModel   OverlayWindowController
              |            |
              `------ PathBarView
```

The separation matters. Tracking code observes Finder, the view model owns
editable path state, and the overlay controller owns the actual `NSPanel`.

## 2. Where the App Starts

Start with these three files:

- `FinderBreadcrumbsApp.swift` contains `@main`, Swift's declaration of the
  program entry point. It connects SwiftUI's app lifecycle to an AppKit delegate.
- `AppDelegate.swift` creates the long-lived coordinator and menu-bar controller.
- `AppCoordinator.swift` wires every subsystem together and translates events
  from one object into commands for another.

`AppCoordinator` is annotated `@MainActor`. This means Swift protects its mutable
UI state by requiring its methods and properties to run on the main actor. AppKit
and SwiftUI UI work should happen there.

The coordinator uses closures such as `tracker.onUpdate` instead of making the
tracker know about windows or views. `[weak self]` prevents a retain cycle:

```swift
tracker.onUpdate = { [weak self] update in
    guard let self else { return }
    // React to the update.
}
```

Without `weak`, the coordinator would own the tracker while the tracker's closure
owned the coordinator, so neither object could be released.

## 3. Configuration

`AppConfig.swift` demonstrates Swift's `Codable` system:

- `AppConfig` is the in-memory representation of `config.json`.
- `JSONDecoder` creates an `AppConfig` from bytes on disk.
- `JSONEncoder` converts the value back to JSON.
- `decodeIfPresent` lets a missing setting fall back to its default, preserving
  compatibility with older config files.
- `AppConfig.Shortcut` has custom encoding so new files use readable values such
  as `cmd+l`, while old numeric shortcut objects still decode.

`AppConfigLoader.load()` creates the default file when none exists. It also calls
`sanitized()` so a zero or negative timer interval cannot accidentally create a
busy loop that consumes a CPU core.

`Shortcut.validationProblem` is the single shortcut policy shared by config
loading and the Settings window. Ordinary keys need Command or Control so a
shortcut such as Shift-A cannot steal text typed into Finder search or rename
fields; function keys may use Option instead. `sanitized()` replaces only an
invalid shortcut, and an unreadable shortcut string falls back on its own, so
one bad value never discards the rest of the config.

The live config is stored at:

```text
~/Library/Application Support/FinderBreadcrumbs/config.json
```

The file is read at app launch. Settings changed through the Settings window are
applied immediately where supported and then saved.

## 4. Tracking Finder

`FinderWindowTracker.swift` is the most complex file because no single public
macOS API provides all required Finder information.

### Core Graphics

`CGWindowListCopyWindowInfo` returns on-screen windows in front-to-back order.
The tracker filters the list by Finder's process ID, visible layer, alpha, and a
minimum size. The first match supplies a window number and frame.

Core Graphics and AppKit use different vertical coordinate systems. The overlay
controller converts the Core Graphics rectangle before positioning the panel.

### Finder Automation

`FinderAutomationService.currentState()` asks Finder for the active window ID and
target folder using Apple Events. This work can block, so tracking requests run
on the serial `stateRefreshQueue`, not on the main thread.

The resulting `FinderState` pairs a directory with a Finder window ID. The ID is
important: it prevents a frame from one Finder window being combined with a path
from another during a rapid window or tab switch.

### Accessibility

When permission is granted, an `AXObserver` reports focused-window, move, and
resize changes. These events improve responsiveness but do not replace polling.
Accessibility also exposes Finder's Quick Look window, allowing the bar to hide
while a preview is open.

Without Accessibility permission, basic tracking still uses Core Graphics and
Apple Events. Motion tracking is less immediate, and Quick Look cannot be
identified reliably.

### Polling and caching

The tracker has three polling speeds:

- `activePollInterval` is the normal rate while Finder is active.
- `motionPollInterval` is the faster rate briefly used around motion.
- `inactivePollInterval` cheaply checks whether Finder has returned.

`FinderStateRefreshCache` avoids running AppleScript at the fast frame polling
rate. `FinderPollReentrancyGate` coalesces a nested refresh request into one
follow-up poll rather than recursively entering mutable tracking state.

Every Finder read gets an increasing ID when it starts. The cache uses those
IDs and timestamps to answer `lookup` with one of four results:

- `.current(state)`: the path is fresh (younger than the greater of 250 ms or
  two active polling intervals), or a visible bar is waiting on a read that
  started less than 1.5 seconds ago. Ordinary latency never flickers the label.
- `.pending`: nothing has confirmed the path yet and the bar is hidden, for
  example after returning to Finder, switching Finder windows, or Quick Look.
  The bar stays hidden until a read that started after that moment finishes,
  instead of flashing a placeholder or showing an outdated path.
- `.unavailable`: Finder confirmed a failure after the path expired, or a read
  is stuck beyond its grace period. The view model clears the old path, cancels
  editing without stealing focus, and shows `Finder location unavailable`. A
  failure never earns read grace, so repeated failures cannot keep a path.
- `.unknownWindow`: the cache has no path for this window. A different window
  never inherits a cached path or unavailable snapshot from the previous window.

A successful read restores normal display and editing.

All system access goes through the small `FinderTrackingEnvironment` protocol:
the clock, whether Finder is frontmost, the frontmost window from Core Graphics,
and the asynchronous Apple Event read. `SystemFinderTrackingEnvironment` is the
production implementation. The regression tests substitute a scripted Finder,
so the real tracker code runs without timers or a live Finder.

### Motion hiding

The overlay intentionally disappears during a move or resize. Accessibility
notifications catch motion when permission is available. A global mouse monitor
also detects Finder border and corner drags, improving resize behavior.

`pendingMotionSnapshot` remembers the newest geometry while hidden. After mouse
release and a short settle delay, the tracker emits that snapshot and the bar
returns at the final position.

## 5. Drawing the Companion Window

`OverlayWindowController.swift` owns a custom `NSPanel` named `FocusablePanel`.
An `NSPanel` is useful for auxiliary UI because it can float without becoming a
normal document window.

Important panel choices include:

- `.borderless` removes standard window chrome.
- `.statusBar` keeps the bar above Finder while it is meant to be visible.
- `.moveToActiveSpace` follows the active macOS Space.
- `canBecomeKey == true` allows the text editor to receive keyboard input.
- `canBecomeMain == false` prevents the companion from behaving like the app's
  main document window.

`update(with:config:)` converts Finder's frame, applies the 4% side insets plus
the configured fixed inset, and places the bar directly beneath Finder.

Clicking the panel begins editing. While editing, a global mouse monitor cancels
the session when the user clicks elsewhere. `onResignKey` is the same-app safety
net for clicks that global event monitors do not report.

## 6. View State and Navigation

`PathBarViewModel.swift` is the source of truth for what the UI displays:

- `@Published` tells SwiftUI to redraw when a property changes.
- `currentState` remembers Finder's latest path and window ID.
- `editingWindowID` pins an edit session to the Finder window where it began.
- `editingSessionID` is a token used to request focus exactly once per session.

`beginEditing()` copies the resolved path into the edit buffer. `commitEditing()`
normalizes the path, resolves symbolic links, and asks `FinderAutomationService`
to navigate the pinned window. A failed navigation leaves edit mode active and
plays the standard macOS alert sound.

If the pinned window has closed, navigation fails rather than selecting another
window or opening a replacement. Calls with no window ID may still open a Finder
window when needed.

Tab completion lists the parent directory and completes only when exactly one
directory starts with the typed fragment. Ambiguous matches do nothing.

## 7. SwiftUI and AppKit Together

`PathBarView.swift` uses SwiftUI for layout but wraps `NSTextField` for precise
macOS field-editor behavior.

`NSViewRepresentable` is the bridge:

- `makeNSView` creates the AppKit view once.
- `updateNSView` synchronizes later SwiftUI state changes into it.
- `Coordinator` acts as the `NSTextFieldDelegate` and sends edits back to the
  SwiftUI binding.

AppKit shares one `NSTextView` field editor per window. That is why caret code
asks the text field or window for its current editor rather than setting a
selection directly on `NSTextField`.

The focus request is retried after `Task.yield()` because SwiftUI may create the
text field before attaching it to an `NSWindow`. The session token prevents those
retries from selecting the text again during ordinary typing.

## 8. The Global Shortcut

`HotKeyManager.swift` wraps Carbon's public hotkey API. Carbon is a C API, so the
code stores opaque references and installs a C-compatible callback function.
`Unmanaged.passUnretained` passes the Swift manager through the C `void *`
context without changing ownership.

The shortcut is registered only while Finder is frontmost. This is crucial for
configurations such as Command-L: Safari and other apps keep their normal
shortcut when Finder is inactive.

Pressing the shortcut does not reuse cached Finder state. The press records the
next read ID, and only a read that started after the press may open the editor.
A routine polling read that was already running is rejected even when it
reports the same window, because the folder may have changed in between. The
tracker lets that read finish, then starts one newer read. It also verifies
that the window ID matches the current frontmost Finder frame and retries once
if the window changed. Repeated presses and forced refreshes share the single
running read plus at most one follow-up, so they never build a queue.
Leaving Finder or the coordinator timeout calls `cancelFreshSnapshotRequest()`,
so a read that finishes later cannot open the editor.

Shortcut completion also checks whether the cache accepted that read and still
considers it current after polling. This matters when the poll discovers a
window switch: even a result naming the new window may have started too early.
Such a result uses the same bounded retry as a window mismatch.

## 9. Permissions and Supporting Windows

- `AccessibilityPermissionManager.swift` wraps the Accessibility trust check and
  Finder Automation consent status.
- `WelcomeWindowController.swift` displays those states. Accessibility is shown
  as Limited rather than Not granted because the polling fallback still works.
- `SettingsWindowController.swift` hosts the settings form and bridges a custom
  AppKit shortcut recorder into SwiftUI. Recording starts from a click (or
  Space), never from initial focus, and continues only while the recorder is
  first responder in the key window. Escape cancels, Tab and Shift-Tab move
  focus, Return reaches the default Save button, and deactivating the window
  stops recording. `SettingsSaveTransaction` validates the shortcut and briefly
  registers it before changing Enable at login, then restores the normal
  Finder-only registration so no shortcut stays reserved in other apps.
  Save also checks the final registration after writing the config. A failure
  attempts to restore the previous config, login setting, and hotkey. Recovery
  attempts every step even if another fails, and the Settings error identifies
  any partial changes it could not undo.
- `LoginItemManager.swift` wraps `SMAppService`, Apple's modern launch-at-login API.
- `StatusMenuController.swift` owns the menu-bar icon and menu actions.

## 10. Concurrency Rules

The project follows three main rules:

1. UI and tracker state are mutated on the main thread/main actor.
2. Polling AppleScript runs on one serial utility queue.
3. Results cross back to the main queue before changing tracker state.

The tracker currently uses `@unchecked Sendable` because its queue handoff is
manually controlled. Treat that annotation as a promise to the compiler, not as
automatic thread safety. New tracker entry points should remain main-thread-only.

The coordinator uses a separate `FinderAutomationService` for navigation and
tracking. This avoids using the same `NSAppleScript` instance simultaneously
from the main thread and the background tracking queue.

## 11. Tests

`Tests/EditingFocusRegressionTests.swift` is a lightweight executable test suite.
It is not XCTest: `@main` runs each function and exits immediately when `expect`
fails. This keeps the prototype simple while covering previously fragile logic.

Run all checks with:

```bash
./check.sh
```

The script first typechecks every production Swift file, then compiles and runs
the regression executable. Tests use mock objects at protocol boundaries so no
real Finder window or permission prompt is required.
Tracker tests use a scripted `FinderTrackingEnvironment` with a manual clock
and finish each Finder read explicitly, which makes timing-sensitive cases
such as slow, failed, or pre-shortcut reads deterministic.

## 12. Known Design Constraints

- Finder path reading and navigation rely on synchronous Apple Events. Navigation
  currently runs on the main actor and can briefly block UI if Finder is slow.
- Quick Look detection requires Accessibility permission.
- Quick Look's `"Quick Look"` AX subrole is observed Finder behavior rather than
  a documented public constant, so a future macOS release could change it.
- Paths containing literal newline characters are legal on APFS but conflict
  with the newline-delimited AppleScript response format.
- The current App Store blockers and distribution options are documented in
  `APP_STORE_COMPLIANCE.md`.

These constraints are good places to learn architectural tradeoffs: each could
be improved, but each improvement adds complexity, permission requirements, or
behavioral risk.
