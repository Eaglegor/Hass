# Central stack — MVP Milestone 1

Brings up the central pieces from [Milestone 1](../../architecture/README.md#milestone-1--core-pipeline-on-device-wake-word--vad-direct-openrouter):
Home Assistant Core, `SpeechToTextEngine` (Vosk over Wyoming), and `TextToSpeechEngine`
(Silero over REST). No `VoiceActivityDetection` container and no LiteLLM proxy yet —
those are Milestones 2 and 3.

This is meant to run on the central host (the N150 mini PC).

## Prerequisites

- Docker Engine + Compose plugin installed (`docker compose version` should work).
- At least one Tier A voice satellite (e.g. an ESP32 device running ESPHome's
  `voice_assistant` component with local wake word) — this stack has nothing to
  say to a microphone by itself.
- An OpenRouter API key.

## Bring it up

```bash
cd deploy/central
cp .env.example .env
# edit .env if you want a different Vosk model/language or Silero settings
docker compose up -d
docker compose logs -f
```

First start will take a while: `wyoming-vosk` downloads the configured Vosk model
into `./data/vosk`, and `silero-tts-service` downloads its model on first request.

**Before trusting the `stt` service's command-line flags**, verify them against the
image's own help output — the exact CLI surface for `rhasspy/wyoming-vosk` wasn't
confirmed from published docs while scaffolding this:

```bash
docker run --rm rhasspy/wyoming-vosk --help
```

Adjust `command:` in `docker-compose.yml` if the flags differ from what's there.

## Configure Home Assistant

Open `http://<n150-ip>:8123`, finish onboarding, then:

### STT — Wyoming integration

Settings → Devices & Services → Add Integration → **Wyoming Protocol** → host
`localhost` (host networking means HA sees `stt`/`tts` on the loopback), port
`10300`. HA should pick it up as a speech-to-text provider automatically.

### TTS — MaryTTS platform (Silero's REST API is MaryTTS-compatible)

The Silero TTS service isn't a Wyoming server — it exposes a REST API compatible
with HA's built-in MaryTTS platform. Add to `config/homeassistant/configuration.yaml`:

```yaml
tts:
  - platform: marytts
    host: localhost
    port: 9898
    codec: "WAVE_FILE"
    language: "ru"
    voice: "REPLACE_ME" # see below
```

Find a real voice name before setting `voice:`:

```bash
curl http://localhost:9898/voices
```

Restart Home Assistant after editing `configuration.yaml`.

### Conversation agent — direct to OpenRouter

Per Milestone 1 there's no LiteLLM proxy yet, so point HA's OpenAI-compatible
conversation integration straight at OpenRouter:

1. Settings → Devices & Services → Add Integration.
2. Look for **OpenRouter** first — if your HA version ships a dedicated
   OpenRouter integration, use it directly with your API key.
3. If it's not available, add **OpenAI Conversation** instead, and when
   configuring it:
   - API key: your OpenRouter key
   - Base URL: `https://openrouter.ai/api/v1`
   - Model: an OpenRouter model slug, e.g. `openai/gpt-4o-mini`
4. Enable "Control Home Assistant" on the conversation agent if you want it to
   expose entities as tool calls (see the architecture doc's notes on this).

### Assist pipeline

Settings → Voice assistants → add a pipeline using the Wyoming STT you just
added, the conversation agent from the previous step, and the MaryTTS-backed
TTS. Wake word stays on the Tier A device itself at this milestone — nothing to
configure centrally for it yet.

## What's deliberately not here yet

- `VoiceActivityDetection` container (Milestone 3).
- `LargeLanguageModelConnector` / LiteLLM proxy (Milestone 2) — OpenRouter is
  wired in directly for now, exactly as designed for this milestone.
- Tier B (post-MVP).
