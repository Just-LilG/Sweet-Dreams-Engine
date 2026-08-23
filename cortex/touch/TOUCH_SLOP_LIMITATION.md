# Micro-Swipe / Small-Movement Dead Zone — Honest Status

## What you're experiencing
Small finger movements (~1cm) get ignored entirely. Move further (~3cm) and
the gesture suddenly registers, "catching up" for the distance that was
ignored. Same symptom on the gyroscope with small device tilts.

## The real cause (confirmed against Android's actual source, not guessed)

This is **Android's touch slop mechanism** — `ViewConfiguration.getScaledTouchSlop()`.
It's a hard distance threshold (default 8dp) below which the OS does not
interpret finger movement as a gesture at all. This is by design: it exists
to stop a stationary tap from being misread as an accidental drag. Below
the threshold, nothing happens; cross it, and the full distance moved
registers at once — which is exactly the "ignored, then jumps" behavior.

We previously wrote a setting called `view_touch_slop` via
`settings put global view_touch_slop <value>`, believing it would lower
this threshold. **It does not work.** We checked Android's actual
`ViewConfiguration.java` source across every API level from Android 1.5
through the current development branch: `mTouchSlop` is set once from a
compiled resource (`config_viewConfigurationTouchSlop` in `config.xml`,
8dp by default) and has no `Settings.Global` key, no settings-provider
hook, no public override of any kind. Writing that setting was a silent
no-op the entire time it existed in this module — it never affected real
touch behavior on your device. We've removed it rather than keep shipping
something that looks like a fix but isn't.

## Why the gyroscope shows the same pattern
Sensor event delivery has its own filtering/batching behavior at the HAL
level, conceptually similar in effect (small changes suppressed, larger
ones delivered in a batch) even though it's a different subsystem than
touch slop. Both landing on the same "ignore small, then catch up on
larger" pattern is why they look connected, even though the underlying
mechanisms are technically separate.

## What we checked for a real fix, and why it's not available on this device
The one legitimate way to influence this at a lower level is the touch
IC's own hardware jitter/noise filter (a real, root-writable kernel node
like `tpd_filter_pixel_num` on some MTK kernels — separate from Android's
software touch slop entirely). We already probe for this in
`cortex/touch/apply.sh`. On this specific device/kernel it does not
exist — confirmed in every single boot log this whole session
(`[TOUCH] Proc/sysfs: no writable nodes`). If a future firmware update
exposes it, our existing probe will pick it up automatically with no
changes needed.

## Bottom line
This is a genuine platform-level constraint on this specific
device/kernel combination right now, not something we're choosing not to
fix. We're not aware of a legitimate, working root-level path to lower it
further given what's actually exposed on this firmware.
