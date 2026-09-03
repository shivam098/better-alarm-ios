# Alarm sounds

This folder is intentionally empty of audio.

The app references a small library of alarm tones by filename (see
`SoundLibrary` in `AlarmyCore`), but no `.caf` files are committed here. Audio
assets are large, and shipping someone else's alarm tones in a public repository
is a licensing problem waiting to happen.

**Nothing breaks without them.** `AlarmKitScheduler` falls back to
`AlertConfiguration.AlertSound.default` whenever a named sound is missing, so
the app builds and alarms ring using the system tone.

## Adding your own

1. Obtain or record audio you have the right to use.
2. Convert it to Core Audio Format. AlarmKit and the system alert sound path
   both want a `.caf` file, and it must be **30 seconds or shorter**:

   ```bash
   afconvert -f caff -d LEI16@44100 input.wav output.caf
   ```

3. Drop the `.caf` files in this folder using the exact filenames listed in
   `SoundLibrary`.
4. Run `make project` so XcodeGen picks up the new resources.

A good alarm tone starts quiet and escalates. A tone that opens at full volume
teaches people to hate their phone; one that ramps gives a light sleeper a
chance to wake gently and a heavy sleeper no way out.
