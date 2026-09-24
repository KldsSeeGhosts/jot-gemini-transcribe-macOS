# Input safety audit

## Scope and diagnosis

This patch addresses input-freeze risks found in a source audit. The reported
intermittent whole-Mac freeze has not been reproduced on the reporter's Mac.

- The active event tap took a shared lock and called client closures on the
  WindowServer input callback. It also immediately re-enabled itself after a
  timeout. A stalled callback could therefore repeatedly hold up global input.
- Stop, startup, and health polling mutated tap resources from different threads.
  A late startup or health callback could outlive shutdown and revive an old tap.
- Synthetic paste suspended on the main actor between key-down and key-up. A busy
  main actor could delay the release far beyond the intended 10 milliseconds.
- The transparent HUD relied on NSView.hitTest returning nil for click-through.
  That does not make an NSWindow transparent to other apps' mouse events.
- A second paste before restoration cancelled the first restore and discarded
  its original clipboard snapshot. Space/Escape gesture repeats and key-ups also
  leaked into the foreground app after their key-down was consumed.

## Changes

The tap now has one run-loop-confined grammar per lifetime, asynchronous ordered
client delivery, explicit port invalidation, and exponential recovery delays
from 1 to 60 seconds. Interrupted holds finalize rather than discard audio.
Settings changes and timers share the tap run loop, and queued deliveries from
stopped generations are ignored. Tagged synthetic events bypass classification.

Paste key pairs run together on a dedicated serial queue, with key-up in defer.
The event source explicitly permits physical input. Clipboard restores require
both the exact session marker and change count, and rapid pastes retain the
original snapshot. Copy-only and user clipboard writes supersede old restores.

The HUD uses window-level ignoresMouseEvents outside its interactive content,
passive pointer monitors, and a panel that cannot become key or main. Informational
states are entirely click-through. The panel no longer uses screen-saver level.

## Validation

InputSafetyTests covers recovery delays, pass-through, synthetic modifiers,
Space/Escape event pairs, same-key updates, interrupted holds, and slow clients.
PasteRestorationTests uses isolated pasteboards and fake posters, never real
keyboard injection. It covers rapid pastes, rich data, user copies, copy-only,
and failed insertion. The existing macOS CI runs the package tests and app build.

Before calling the original intermittent freeze resolved on hardware, verify:

1. Hold/release, Space-lock, held Space/Escape, repeated short takes, and changing
   the selected modifier during a hold. No ordinary typing or clicks should stall.
2. Sleep/wake during recording and exercise the hotkey while the app is busy.
   Check History for the interrupted recording and verify recovery afterward.
3. Click through the empty HUD stage and every informational state. Dictate and
   Stop should still work without taking keyboard focus. Drag across the stage
   from another app and test multiple displays and full-screen windows.
4. Dictate twice within a second, including rich clipboard data; copy new content
   during restoration; cancel during paste. Verify clipboard ownership and that
   subsequent physical keys/clicks are unaffected.
