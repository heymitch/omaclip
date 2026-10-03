# Roadmap

## Next: transcripts and smart titles ("Connect your agent")

After an upload, the server transcribes the clip and asks a model for a title, then
rewrites the clip page in place. The link never changes.

**Flow**

1. Upload returns the link immediately, as today.
2. A background worker on the server (one clip at a time) transcribes the video, then asks a
   model for a title and a one-line summary.
3. It rewrites `index.html` and `oembed.json` with the new title and summary, adds captions
   (`captions.vtt` as a `<track>`, useful for muted viewing) and puts the transcript on the page.
4. The panel's recent list picks up the new title.

**Models**

Both steps talk to OpenAI-compatible endpoints, so "Connect your agent" is two URLs plus an
optional key:

- Transcription: `/v1/audio/transcriptions`. Default: faster-whisper `small` (int8, CPU) on
  the VPS.
- Titles: `/v1/chat/completions`. Default: a ~3B open model (Qwen 2.5 3B or Llama 3.2 3B,
  Q4) under llama.cpp's `llama-server` on the VPS.
- Or the user's own: Ollama elsewhere, OpenRouter, any compatible API, or their own agent.

On a 6-core CPU-only VPS with ~6 GB free RAM, rough guesses still to be measured: transcripts
in about 1–3 minutes for a 5-minute clip; titles in under a minute.

**Pieces**

- `server/`: worker plus page rewrite (~200 lines); env vars for the two endpoints, model
  names and key.
- Panel: a "Connect your agent" section (endpoints, key, Test), like the Server section.
- `SKILL.md`: instructions an agent (Claude Code, Codex, Hermes) follows to install
  faster-whisper and llama.cpp on the VPS, fetch the models, run them as services, point the
  omaclip server at them, and verify with a test clip. The README covers the manual path too.

**Open decisions**

- Slack, iMessage and others cache link previews at first paste. Choose the default between
  copying the link immediately (title shows up only on later shares) and waiting for the title
  before copying (about a minute for short clips). Make it a setting either way.
- Shared VPSes: keep the queue at one job and models small; document memory needs.
