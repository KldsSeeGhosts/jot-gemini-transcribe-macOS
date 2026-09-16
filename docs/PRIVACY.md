# Privacy

## The promise

Your voice goes from your Mac directly to OpenAI Realtime, using the local OAuth
session created by Pi or Codex. There is no middleman server, no app account, no
analytics, no telemetry.
Everything else stays on your Mac. The code is open — verify all of this.

## What leaves your machine (the complete list)

1. **The audio of each dictation**, sent to `api.openai.com`, the only network
   host this app talks to. Live mode streams 24 kHz PCM. The fallback and
   recovery path replays 24 kHz PCM from the saved CAF through Realtime.
2. **Your dictionary terms**, alongside that audio. The transcription model uses
   them to bias what it hears, which is why names and jargon come out spelled
   right as you speak rather than being corrected afterwards. Only the correct
   spellings are sent — never the misspellings you record. They ride on every
   dictation, including with Smart transcription off.
3. **The transcription prompt**, when Smart transcription, tone matching, or
   dictionary terms are enabled. It contains formatting rules, dictionary terms,
   and a coarse category derived from the target app when tone matching is on.
   It never contains window contents, screenshots, surrounding text, or a prior
   transcript.
4. **Your OAuth access token and ChatGPT account ID**, in request headers to
   OpenAI only. Jot reads the existing Pi or Codex credential file and refreshes
   it when needed. Jot never logs token values.

## What never leaves

- Your history database and stored recordings — audio and transcript text leave
  only as part of the requests above, never in bulk and never anywhere else
- Your dictionary as a file. Individual correct spellings ride with the audio as
  described above. Misspelling rules run locally after transcription. The store
  itself stays on this Mac
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

Your requests use the ChatGPT-managed Codex OAuth session already present on
your Mac. Jot does not broker that relationship. OpenAI's official
authentication documentation states that ChatGPT OAuth is intended for Codex
clients and that general OpenAI API calls should use Platform API keys. Jot
therefore uses only the Realtime transcription route verified by the companion
dictation project, not the recorded-audio or Responses endpoints. Review
[OpenAI authentication](https://learn.chatgpt.com/docs/auth).

## Secure input

When a password field is focused (secure input), dictation refuses to start, and
a transcript in flight is held in History only — never inserted, never placed on
the clipboard.

## Verify it

- Build from source (`./scripts/build.sh`).
- Watch traffic with Little Snitch or `nettop` — you'll see exactly one host.
- Read the transcription prompt construction in
  ([OpenAITranscriptionService.swift](../JotCore/Sources/TranscriptionClient/OpenAITranscriptionService.swift)).
