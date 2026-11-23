# Teleprompter

A small, always-on-top teleprompter for macOS, built for reading a script while
on camera: recording videos, demos, presentations or livestreams. It sits at the
top of the screen, close to the webcam, and keeps the line you're on pinned at the top.

## Features

- **Voice-follow (default).** On-device speech recognition moves the script along
  as you say it. Spoken words turn black; upcoming words stay gray. It holds still
  while you ad-lib and catches up if you skip a sentence. Audio never leaves your Mac.
- **Timed mode.** Scrolls at a fixed pace (60–260 words per minute), pausing
  briefly at commas, sentence ends and paragraph breaks.
- **Two reading styles.** *Top to bottom* wraps the script into lines and keeps
  your line pinned at the top. *Side to side* shows one line that moves right to
  left like a news ticker, with the current word a third of the way across.
- **See-through mode.** Clears the white background so you can see the window
  behind it, while the script text stays solid.
- **Global hotkeys** that work while another app (like your browser) is in front.
- Floats above other windows and full-screen apps, and remembers your script,
  speed, text size and window position.

## Requirements

- macOS 26 or later on Apple silicon
- Xcode Command Line Tools (`xcode-select --install`); full Xcode isn't needed

## Build and install

```bash
./build.sh   # builds Teleprompter.app and installs it into /Applications
./test.sh    # runs the pacing and voice-matching tests
```

On first use of voice mode, macOS asks for Microphone and Speech Recognition
access and may download Apple's English speech model.

## Using it

Hover over the window to show the controls. Click **Edit**, paste your script,
click **Done**, then press play.

| Hotkey (works from any app) | Action |
| --- | --- |
| `⌃⌥Space` | Play / pause (in voice mode: start / stop listening) |
| `⌃⌥←` | Back one sentence |
| `⌃⌥→` | Skip ahead one sentence |
| `⌃⌥R` | Restart |
| `⌃⌥T` | Toggle see-through |
| `⌃⌥↑` / `⌃⌥↓` | Faster / slower (timed mode) |

With the window focused, the same keys work without `⌃⌥`, and `⌘+` / `⌘−` change
the text size. See-through can also be toggled from the eye button in the title
bar or the icon in the menu bar.

## How voice-follow works

The recognizer's output is noisy: it mishears words ("teleprompture"), splits
hyphenated ones ("Control Option Space"), and hears everything you ad-lib.
`VoiceFollower` lines that transcript up against the script:

1. A heard word that matches the next script word advances. Small mishearings are
   allowed: one edit for words of 4+ letters, two for words of 8+.
2. A match one or two words ahead advances too, in case the recognizer dropped a word.
3. Three heard words in a row matching the script further ahead, within the next
   two sentence endings, jump there, in case you skipped something.
4. Anything else is treated as ad-lib, and the position holds.

The matching and pacing logic (`Sources/VoiceFollower.swift`, `Sources/Pacer.swift`)
has no UI dependencies, so it's covered by plain tests in `Tests/main.swift`.

To see exactly what the recognizer hears, launch with logging on:

```bash
open --env TELEPROMPTER_DEBUG=1 --stderr /tmp/teleprompter.log /Applications/Teleprompter.app
```

## License

[MIT](LICENSE)
