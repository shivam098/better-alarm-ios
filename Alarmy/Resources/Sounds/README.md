# Alarm sounds

Seven original synthesized tones are committed here as four-second, mono,
16-bit PCM WAV files at 22,050 Hz. No third-party recordings are used.
The stable sound IDs in saved alarms have not changed.

Regenerate deterministically with `node tools/generate-sounds.mjs`, then run
`make project` on a Mac so XcodeGen includes the resources.

AlarmKit uses the selected tone, with the system default as a missing-file
fallback. Mission Guard and wake-check re-alarms use the configured backup
tone. In-app playback tries the requested tone, backup, then Radar; if all fail
it reports the error and attempts a repeating system alert.

The configurable ramp, spoken label/time, app volume and vibration apply to
in-app mission playback only. iOS controls system alarm volume, vibration and
accessory routing. These controls do not override the hardware volume, phone
calls, a powered-off phone or missing alarm authorization.
