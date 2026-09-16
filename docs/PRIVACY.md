# Privacy

## The promise

Your voice goes from your Mac directly to the OpenAI API, using your own API
key. There is no middleman server, no app account, no analytics, no telemetry.
Everything else stays on your Mac. The code is open — verify all of this.

## What leaves your machine (the complete list)

1. **The audio of each dictation**, sent to `api.openai.com`, the only network
   host this app talks to. Live mode streams 24 kHz PCM. The fallback and
   recovery path uploads an M4A copy made from the saved CAF.
2. **Your dictionary terms**, alongside that audio. The transcription model uses
   them to bias what it hears, which is why names and jargon come out spelled
   right as you speak rather than being corrected afterwards. Only the correct
   spellings are sent — never the misspellings you record. They ride on every
   dictation, including with Smart transcription off.
3. **The formatting prompt**, when Smart transcription or "Match tone to the app
   you're in" is on. Smart transcription is on by default. It contains the raw
   transcript, formatting rules, and dictionary terms. Tone matching also adds a
   coarse category derived from the target app, such as "chat message". It never
   contains window contents, screenshots, or surrounding text.
4. **Your API key**, in the request header to OpenAI only. It is stored in the
   macOS Keychain, never in files or preferences.

## What never leaves

- Your history database and stored recordings — audio and transcript text leave
  only as part of the requests above, never in bulk and never anywhere else
- Your dictionary as a file. Individual terms ride with the audio as described
  above, and your misspelling rules are included in the formatting prompt when
  Smart transcription or tone matching is on. The store itself, and everything
  you have not dictated against, stays on this Mac
- Which apps you use, when you dictate, or anything you type
- Keystrokes: the event tap watches your dictation key, plus — only while a
  dictation is active — Esc (cancel), Space (the hands-free gesture), and the
  *fact that* another key was pressed (the accidental-chord guard; which key it
  was is never examined beyond its keycode, never logged, never stored, never
  transmitted). When you're not dictating, other keys pass through untouched.
- Screenshots: never taken. The app contains no screen-capture code.
- Telemetry: there is none. No analytics SDK, no crash uploader, no phone-home.

## What's stored locally, and your controls

- One folder per dictation (`~/Library/Application Support/Jot/recordings/`):
  crash-safe audio, transcript, metadata — this is what makes Retry and recovery work.
- Settings → Privacy & Storage: audio retention (24h / 7d / 30d / forever / never —
  "never" disables Retry), plus one-click **Delete all history**.
- Local files are protected by FileVault if enabled; they are not separately
  encrypted (stated honestly).

## OpenAI's side of the wire

Your requests are governed by the terms and data controls of your own OpenAI API
account. Jot does not broker that relationship. Review OpenAI's current
[API data usage documentation](https://platform.openai.com/docs/guides/your-data).

## Secure input

When a password field is focused (secure input), dictation refuses to start, and
a transcript in flight is held in History only — never inserted, never placed on
the clipboard.

## Verify it

- Build from source (`./scripts/build.sh`).
- Watch traffic with Little Snitch or `nettop` — you'll see exactly one host.
- Read the cleanup prompt used by Smart transcription and tone matching
  ([PromptV1.swift](../JotCore/Sources/FormattingPipeline/PromptV1.swift)).
