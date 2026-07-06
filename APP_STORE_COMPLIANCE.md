# Mac App Store Compliance Notes

Status as of **2026-07-05** (pre-release, app not sandboxed yet).

**Verdict: the app cannot ship on the Mac App Store as currently built.** No private
or prohibited APIs are used — the problem is that the App Store's mandatory App
Sandbox (Guideline 2.4.5(i)) conflicts with all three core mechanisms of the app.
Every blocker below includes the options for fixing it if App Store distribution
becomes a goal.

---

## Hard blocker 1 — AppleScript automation of Finder

**Where:** `FinderBreadcrumbs/FinderAutomationService.swift`
(`NSAppleScript` reading `target of front window`, and setting it on navigate).

**Problem:** Sandboxed apps may not send Apple Events to other apps. The two
sanctioned escape hatches both fail here:

- `com.apple.security.scripting-targets` — only works when the target app
  publishes scripting access groups. Finder does not, so this entitlement is
  unusable.
- `com.apple.security.temporary-exception.apple-events` (targeting
  `com.apple.finder`) — technically possible, but explicitly "temporary,"
  requires written justification in App Review notes, is approved case-by-case,
  and can be rejected on any future update. The entire product would depend on
  reviewer discretion.

**Fixes if shipping on the App Store:**

1. Submit with the temporary-exception entitlement for `com.apple.finder` plus
   review notes explaining that reading/setting the frontmost Finder folder *is*
   the product. Accept the rejection risk and the risk of losing approval later.
2. There is no sandbox-safe replacement API for "what folder is this Finder
   window showing." (Accessibility attributes could theoretically expose the
   document path, but that runs into Blocker 2.) If the exception is refused,
   the core feature cannot exist in a Store build.

**Keep regardless:** `NSAppleEventsUsageDescription` in Info.plist (already
present). For any distribution with Hardened Runtime, also add the
`com.apple.security.automation.apple-events` entitlement.

---

## Hard blocker 2 — Accessibility API usage

**Where:** `FinderBreadcrumbs/FinderWindowTracker.swift` (`AXObserverCreate`,
`AXUIElementCopyAttributeValue`, move/resize notifications on Finder windows)
and `FinderBreadcrumbs/AccessibilityPermissionManager.swift`.

**Problem:** Requires the user-granted Accessibility permission. App Review's
treatment of sandboxed apps that use AX APIs is inconsistent: a few window
managers (e.g. Magnet) have been approved, but reliance on Accessibility is a
commonly cited rejection ground under Guideline 2.5.1. It cannot be counted on.

**Fixes if shipping on the App Store:**

1. Drop AX usage from the Store build entirely (compile it out behind a build
   flag). The tracker already degrades gracefully: without AX it falls back to
   pure `CGWindowList` polling — window tracking is less fluid during drags,
   but functional.
2. If keeping AX, be prepared to justify it in review notes and to remove it on
   demand. Do not make any core feature depend on it (currently true — it only
   improves motion tracking).

---

## Hard blocker 3 — Arbitrary filesystem reads

**Where:** `FinderBreadcrumbs/PathBarViewModel.swift`
(`completePathIfUnambiguous` calls `contentsOfDirectory` on whatever path the
user typed) and `FinderAutomationService.navigate` (checks
`fileExists(atPath:isDirectory:)` before navigating).

**Problem:** The sandbox denies reads outside the app container and
user-selected locations. Under sandbox, tab-completion silently returns nothing
and `navigate` refuses folders it cannot stat — i.e. typing a valid path would
do nothing. Broken core flows fail review on their own (Guideline 2.1, app
completeness).

**Fixes if shipping on the App Store:**

1. Request read access entitlements for well-known areas
   (`com.apple.security.files.user-selected.read-only` plus e.g.
   `com.apple.security.files.downloads.read-only`) and/or use
   security-scoped bookmarks: let the user grant folders once via `NSOpenPanel`
   and persist the bookmarks. Completion then only works inside granted trees.
2. Remove the local existence check in `navigate` for a Store build and let
   Finder itself reject invalid paths (report failure from the AppleScript
   result instead).
3. Simplest: disable tab-completion in the Store build.

---

## Not blockers (verified fine)

| Mechanism | Status |
| --- | --- |
| `RegisterEventHotKey` (Carbon global hotkey) | Public API, sandbox-compatible, widely used in MAS apps |
| `CGWindowListCopyWindowInfo` | Fine — only bounds/PID/layer/alpha are consumed. Window *titles* would need Screen Recording permission, but titles are only read for debug diagnostics |
| Overlay `NSPanel` at `.statusBar` level, `activate(ignoringOtherApps:)` | Allowed |
| Global mouse-down monitor (`NSEvent.addGlobalMonitorForEvents`) | Mouse monitors need no special permission (keyboard monitors would) |
| `SMAppService.mainApp` login item | The approved mechanism; correctly opt-in via Settings |
| `NSAppleEventsUsageDescription`, `LSUIElement` in Info.plist | Present and correct |
| Private APIs | None found |
| Config file in Application Support | Fine (relocates into the container under sandbox) |

---

## Recommended path instead: Developer ID + notarization

Finder enhancers and window utilities (Bartender, Rectangle, Alfred, Default
Folder X) ship outside the Mac App Store precisely because of the blockers
above. Everything this app does is fully legitimate under Developer ID:

1. Sign with a real Developer ID certificate (also permanently fixes the
   ad-hoc-signature problem where every rebuild resets TCC permission grants).
2. Enable Hardened Runtime and add the
   `com.apple.security.automation.apple-events` entitlement.
3. Notarize with `notarytool` and staple the ticket.
4. Distribute directly (DMG/ZIP, Sparkle for updates) or via a platform like
   Setapp.

No sandbox, no entitlement exceptions, no feature cuts.

---

## Quick reference: exact entitlements and APIs

### Entitlements — Mac App Store build

Everything the Store build would need in its `.entitlements` file:

```xml
<!-- Mandatory for all MAS apps -->
<key>com.apple.security.app-sandbox</key>
<true/>

<!-- Blocker 1: Apple Events to Finder (approval at App Review's discretion) -->
<key>com.apple.security.temporary-exception.apple-events</key>
<array>
    <string>com.apple.finder</string>
</array>

<!-- Blocker 3, only if keeping tab-completion: user-granted folder access -->
<key>com.apple.security.files.user-selected.read-only</key>
<true/>
<!-- …and to persist those grants across launches via security-scoped bookmarks -->
<key>com.apple.security.files.bookmarks.app-scope</key>
<true/>
```

Note: `com.apple.security.scripting-targets` is listed in Blocker 1 only to
document why it does NOT work here (Finder publishes no access groups) — do not
add it.

### Entitlements — Developer ID build (recommended)

With Hardened Runtime enabled, only one entitlement is needed:

```xml
<key>com.apple.security.automation.apple-events</key>
<true/>
```

`com.apple.security.get-task-allow` appears in Debug builds automatically;
Release/archived builds must not carry it (Xcode strips it on archive).

### Info.plist keys (both paths, already present)

- `NSAppleEventsUsageDescription` — shown in the Automation consent prompt.
- `LSUIElement` — menu-bar app, no Dock icon.

### APIs currently used (all public)

| API | Purpose | Notes |
| --- | --- | --- |
| `NSAppleScript` | Read/set Finder's folder | Gated by Automation TCC consent |
| `AEDeterminePermissionToAutomateTarget` | Welcome-screen permission check | Blocks when prompting; call off main thread |
| `AXIsProcessTrustedWithOptions`, `AXObserverCreate`, `AXUIElementCopyAttributeValue` | Window move/resize tracking | Gated by Accessibility TCC; drop for MAS build |
| `CGWindowListCopyWindowInfo` | Find Finder window frame | No permission needed for bounds/PID/layer/alpha |
| `RegisterEventHotKey` / `InstallEventHandler` (Carbon) | Global hotkey | Sandbox-safe |
| `NSEvent.addGlobalMonitorForEvents` (mouse down) | Dismiss edit mode on outside click | No permission needed for mouse events |
| `SMAppService.mainApp` | Launch at login | Approved mechanism |

### APIs to add only for a MAS build with tab-completion

- `NSOpenPanel` — one-time folder grants from the user.
- `URL.bookmarkData(options: .withSecurityScope)` and
  `URL(resolvingBookmarkData:options: .withSecurityScope)` — persist/restore grants.
- `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` —
  bracket directory reads inside granted trees.

### Signing & notarization commands (Developer ID path)

```bash
xcodebuild archive # sign with "Developer ID Application" identity
xcrun notarytool submit Breadcrumbs.zip --keychain-profile <profile> --wait
xcrun stapler staple Breadcrumbs.app
```
