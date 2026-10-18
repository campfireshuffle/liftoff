# Mac App Store

Can Liftoff ship on the Mac App Store? Apps sold there must run in the App Sandbox (App Review
Guideline 2.4.5), so this page records what happens to each part of Liftoff when it runs sandboxed.

**Verdict: no-go for now.** Most of the app works in the sandbox, but moving another app's window
doesn't. That's the one thing Liftoff can't do without, and the only workaround that worked
depends on an entitlement App Review rarely grants. Keep shipping direct (Developer ID, Homebrew).

## How it was tested

`SANDBOX=1 scripts/package.sh` builds `dist/Liftoff.app` with `Liftoff.sandbox.entitlements`,
which holds `com.apple.security.app-sandbox` and nothing else. The app was signed with the local
"Liftoff Dev" identity and tested on macOS 27.0.1. Without `SANDBOX=1` the script builds exactly
what it built before.

Temporary logging, since removed, recorded each permission check and each API result from inside
the sandboxed process. Synthetic events posted at the HID level tested the event tap: a Hyper
`flagsChanged` (all four modifiers, the way Raycast sends them) and then a left drag. A second,
listen-only tap further down the chain counted how many of those events got past Liftoff.

The test build kept the bundle ID and signing identity of the dev build, so it inherited that
build's Accessibility and Screen Recording grants. That means these results show what the sandbox
allows. They don't show what a fresh App Store install would be asked for (see
[Permissions](#permissions)).

## Results

| Capability | Sandboxed | Notes |
| --- | --- | --- |
| Event tap (`InputTap.swift`) | Works | The active tap at `.cgSessionEventTap` / `.tailAppendEventTap` is created. It sees Raycast-style Hyper `flagsChanged` and real modifier presses. Returning `nil` still swallows the drag: with a grab forced, 0 of 7 mouse events got past it, against 7 of 7 without one. It doesn't need to become listen-only. |
| Finding windows (`CGWindowListCopyWindowInfo`) | Works | Same list as outside the sandbox. |
| Moving other apps' windows (AX, `WindowSystem.swift`) | **Blocked** | `AXIsProcessTrusted()` returns `true`, but every call to another app's element (`kAXWindowsAttribute`, even `kAXRoleAttribute`) fails with `kAXErrorCannotComplete` (-25204). Tried against Messages, Chess, Dia and Preview. So `WindowSystem.element(for:)` returns nil and nothing can be grabbed. |
| ScreenCaptureKit (`Snapshotter.swift`) | Works | `SCShareableContent` lists windows, and `SCScreenshotManager.captureImage` returned full-resolution snapshots (3776×2118 and 3900×2120). |
| Overlay, jets and particles | Works | The full-screen overlay window (layer 102) comes up, and the welcome window flies in with jets and a touchdown burst. All of this is drawing inside Liftoff's own windows, which the sandbox doesn't restrict. |
| Hiss (`AVAudioEngine`) | Works | The engine starts and runs on the output device. Output needs no entitlement. |
| Debug hooks | Work | The sandbox still delivers distributed notifications, but an App Store build should leave the hooks out anyway. |

The window move failing is expected. Apple DTS says the Accessibility APIs aren't supported in
sandboxed apps ([forum thread 794253](https://developer.apple.com/forums/thread/794253)): "We do
not support the Accessibility APIs in sandboxed apps." Mac App Store window managers that use AX,
like Magnet, either predate the sandbox requirement or aren't sandboxed
([thread 707680](https://origin-devforums.apple.com/forums/thread/707680)). A new app can't take
that route.

## The one workaround that worked: System Events

The drag itself isn't the problem, since the tap still swallows it. What's missing is any way to
move another app's window. Liftoff only moves the real window twice per throw: it parks the window
at grab time, then puts it back on landing. The snapshot flies in between. That makes a slow
mover workable.

The prototype asked System Events through `NSAppleScript` to find the target window in the
target process (matching position and size) and set its position. That needs:

- `com.apple.security.temporary-exception.apple-events` = `["com.apple.systemevents"]`
- `com.apple.security.automation.apple-events` = `true` (needed under the hardened runtime)
- `NSAppleEventsUsageDescription` in `Info.plist`. Without it, macOS refuses straight away
  (-1743, "Not authorized to send Apple events to System Events") and never shows a prompt.

With all three, macOS asked for Automation consent once. After that, Chess's window moved there
and back. The first call took about 2.9 s, because it included the consent prompt and launching
System Events. Later calls took 200–270 ms each. System Events does the AX work itself, on behalf
of Liftoff, using Liftoff's Accessibility grant.

To ship this, the app would need these changes:

- `WindowSystem` would be rebuilt on Apple Events. A window gets identified by its pid plus its
  frame, not by an `AXUIElement`. Raising it becomes `perform action "AXRaise"`, and the
  `AXEnhancedUserInterface` workaround goes through `value of attribute`. Each move costs about
  200 ms, so moves have to run off the main thread, which they already do in `moveInBackground`.
- Grabbing gets slower. Parking happens in the background, so the snapshot hides it. Landing
  waits about 0.2 s before the real window is back.
- Users get a third permission prompt: "Liftoff wants to control System Events."

None of this code is committed. It shows the route works technically. App Review is what blocks it.

## Permissions

A fresh App Store install needs a different signing identity, so it can't inherit any grants.
It would ask for:

- **Accessibility**: the active tap needs it to swallow the drag. DTS calls this the `PostEvent`
  privilege and says it's compatible with the sandbox, though System Settings lists it under
  Accessibility ([thread 820594](https://developer.apple.com/forums/thread/820594)). The System
  Events route also relies on it. `AXIsProcessTrustedWithOptions`'s prompt reportedly doesn't
  appear for sandboxed apps, so onboarding would call `CGRequestPostEventAccess()` instead.
- **Screen Recording**: for the snapshots. `CGRequestScreenCaptureAccess()` works sandboxed.
- **Automation (System Events)**: only for the workaround above.
- **Input Monitoring**: only if the tap became listen-only. It doesn't have to.

These requests weren't seen fresh in this test, because the grants carried over. Only the
Automation prompt was new.

## Entitlements an App Store build would need

```xml
<key>com.apple.security.app-sandbox</key>              <true/>
<!-- only for the System Events workaround: -->
<key>com.apple.security.automation.apple-events</key>  <true/>
<key>com.apple.security.temporary-exception.apple-events</key>
<array><string>com.apple.systemevents</string></array>
```

Plus a Mac App Store provisioning profile and the Apple Distribution certificate. Leave
`DebugHooks.swift` and `Recorder.swift` out of the build.

## App Review risks

- **Temporary exception for System Events.** This is the main risk. Each temporary exception gets
  its own justification and review, and an exception that lets an app script System Events (and
  so control every app) is the kind reviewers push back on. DTS calls Apple Events exceptions a
  poor fit for App Store distribution, since the sandbox exists to stop one app changing another's
  state ([thread 794253](https://developer.apple.com/forums/thread/794253)). Expect a rejection,
  or a back-and-forth with no guaranteed outcome.
- **2.4.5 / "Accessibility for non-accessibility purposes".** Reviewers have rejected sandboxed
  apps for using the Accessibility-listed event privilege outside accessibility uses, even though
  DTS says it's sandbox-compatible
  ([thread 820594](https://developer.apple.com/forums/thread/820594)). Liftoff would need that
  privilege to swallow the drag, and System Events would need it to move windows.
- **4.2 minimum functionality.** This risk is low. Liftoff is a complete, distinctive utility, not
  a repackaged website or a thin wrapper. A whimsical window flinger could still get "not useful
  enough" pushback. Pitch it as window management with physics, and show the settings and
  onboarding.
- **Three privacy prompts** (Accessibility, Screen Recording, Automation) for a playful utility.
  Each needs a clear purpose string and an explanation on the welcome screen. Reviewers check
  that every prompt matches a feature they can see.

## Recommendation

**No-go.** Liftoff's core feature, moving other apps' windows, is blocked by design in the App
Sandbox. The only way through, a temporary Apple Events exception for System Events, works
technically, but App Review is unlikely to approve it. Even then, the app would get slower to
land and pick up a third permission prompt. The rest of the app (tap, Hyper detection, swallowed
drags, ScreenCaptureKit, overlay, particles, audio) would carry over unchanged.

If you still want to try, a cheap test is possible: build the System Events version and submit it
to TestFlight or App Review with a clear justification for the exception. If it's rejected, the
cost is that one branch. Otherwise, keep distributing signed and notarized builds directly, and
look for ways to get onto r/macapps that don't depend on the App Store.
