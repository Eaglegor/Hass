# Central stack — MVP Milestone 1

**Status: verified working end-to-end** on real hardware — wake word (local, ESPHome
ReSpeaker satellite) → STT (Vosk/Wyoming) → OpenRouter LLM (conversation agent) →
TTS (Silero) → spoken response, actually heard out of the ReSpeaker's speaker.

Brings up the central pieces from [Milestone 1](../../architecture/README.md#milestone-1--core-pipeline-on-device-wake-word--vad-direct-openrouter):
Home Assistant Core, `SpeechToTextEngine` (Vosk over Wyoming), and `TextToSpeechEngine`
(Silero, via [indevor/silero-tts-enhanced-addon](https://github.com/indevor/silero-tts-enhanced-addon) +
its [HACS companion integration](https://github.com/indevor/silero-tts-enhanced-hacs)).
No `VoiceActivityDetection` container and no LiteLLM proxy yet — those are Milestones 2 and 3.

Note on the TTS choice: `indevor/silero-tts-enhanced-addon` is packaged as a Home
Assistant OS **Add-on** (Supervisor-only), which doesn't run on our Container-based
setup as-is. It turned out to be a plain FastAPI/Uvicorn app with no Supervisor
dependency underneath (`"options": {}` in its `config.json`, an ordinary
`Dockerfile`), so `docker-compose.yml` here builds it directly from the add-on's
own repo instead of using it as a Supervisor add-on. Two other Silero options were
tried and ruled out first: `navatusein/silero-tts-service` (REST, MaryTTS-shaped)
doesn't work because the `marytts` TTS platform is a **dead legacy stub** in
current Home Assistant — it shows up as a recognized integration but creates zero
entities; and `ganiushin/parakeet-stt-silero-tts-addons-haos`'s Wyoming-Silero
server is also Supervisor-add-on-only.

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
# edit .env if you want a different Vosk model/language
docker compose up -d --build
docker compose logs -f
```

`--build` matters here: `tts` isn't a pre-built image, it's built from
`indevor/silero-tts-enhanced-addon`'s repo directly (see note above) — this will
take noticeably longer than a plain `docker compose up -d` the first time, since
Docker has to clone the repo and install `silero-tts`/`torch` and friends inside
the image build itself, on top of the model download that happens later at
runtime.

First start will take a while: `wyoming-vosk` downloads the configured Vosk model
into `./data/vosk`, and the Silero TTS engine downloads its model into
`./data/silero` on its first `/tts` request (not at container startup).

The `stt` service's flags were confirmed against `docker run --rm rhasspy/wyoming-vosk --help`.
Note there's no plain `--model` flag: model selection goes through
`--model-for-language <language> <model>` (two values), and `--preload-language`
loads the model at startup instead of lazily on the first request — both are
already wired up in `docker-compose.yml` via `VOSK_LANGUAGE`/`VOSK_MODEL`.

There's also an upstream `wyoming-vosk` bug worth knowing about: `--preload-language`
unconditionally calls into sentence-loading code that crashes on a `None` path if
`--sentences-dir` isn't set, even though we're not using sentence
correction/limiting at all. `docker-compose.yml` already works around this with
`--sentences-dir /data/sentences` (an empty directory is fine — a missing
`<language>.yaml` there is handled gracefully). If `stt` crash-loops with a
`TypeError: expected str, bytes or os.PathLike object, not NoneType` traceback
pointing at `load_sentences_for_language`, this is why.

**Don't try `vosk-model-ru-0.54` as a bigger/more-accurate alternative** — it looks
like a natural upgrade from `vosk-model-small-ru-0.22`, but Alpha Cephei's current
"big" Russian model is a k2/icefall/sherpa export (`am`, `am-onnx`, `lang`, `lm`,
`decode*.py`), not a classic Vosk-API-shaped model (`am/conf/graph/ivector`). The
`vosk` Python package's `Model()` constructor can't load it at all — you'll get
`Folder '/data/vosk-model-ru-0.54' does not contain model files` regardless of how
carefully it's downloaded/placed. Also note `wyoming-vosk`'s auto-downloader only
mirrors `vosk-model-small-ru-0.22` for Russian (from `rhasspy/vosk-models` on
Hugging Face, not Alpha Cephei directly) — any other Russian model name has to be
downloaded and placed manually, and as this shows, that doesn't guarantee it'll
actually load. Better Russian STT accuracy is a real open problem, not a config
tweak — see the architecture doc's notes on the Whisper fallback.

## Configure Home Assistant

Open `http://<n150-ip>:8123`, finish onboarding, then:

### STT — Wyoming integration

Settings → Devices & Services → Add Integration → **Wyoming Protocol** → host
`localhost` (host networking means HA sees `stt`/`tts` on the loopback), port
`10300`. HA should pick it up as a speech-to-text provider automatically.

### TTS — HACS custom integration (not YAML, not Wyoming, not MaryTTS)

The `tts` container exposes a plain REST API (`POST /tts` with a JSON body,
returns a WAV file) on port `8014` — there's no Wyoming or MaryTTS compatibility
here, it needs its own HA-side integration:

1. **Install HACS** first, if you haven't (Container installs don't come with
   it — HAOS-only add-ons like the ones we ruled out above assume it's there,
   plain custom integrations need it explicitly):
   ```bash
   sudo docker compose exec homeassistant bash
   cd /config
   wget -O - https://get.hacs.xyz | bash -
   exit
   sudo docker compose restart homeassistant
   ```
   Hard-refresh your browser (Ctrl+Shift+R), then Settings → Devices & Services
   → Add Integration → **HACS** → follow the GitHub device-activation flow.
2. In HACS → **Custom repositories**, add
   `https://github.com/indevor/silero-tts-enhanced-hacs` as an **Integration**.
3. Install it from HACS, restart Home Assistant.
4. Settings → Devices & Services → Add Integration → search for the Silero TTS
   Enhanced integration. When it asks for the server address, point it at
   `http://localhost:8014` (host networking again) and pick a voice/language
   from its UI.

Sanity-check the backend directly before wiring up the HA side, if you want:

```bash
curl -X POST http://localhost:8014/tts \
  -H "Content-Type: application/json" \
  -d '{"text": "Привет, это тест", "voice": "xenia", "language": "ru"}' \
  --output /tmp/test.wav
```

A non-empty, playable `test.wav` means the backend itself is working, independent
of whatever HA-side wiring comes next.

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
added, the conversation agent from the previous step, and the Silero TTS
integration from the previous section. Wake word stays on the Tier A device
itself at this milestone — nothing to configure centrally for it yet.

### Adding an ESPHome-based Tier A satellite (e.g. a ReSpeaker)

An existing ESPHome voice satellite (running the `voice_assistant` component with
local wake word) doesn't need reflashing to move to a new HA instance — it just
needs to be reachable on the same network and re-added:

- Settings → Devices & Services → check **Discovered** (HA's host networking plus
  the device being on the same LAN/VLAN means mDNS discovery should just find it),
  or **Add Integration → ESPHome** and enter its IP manually if not discovered.
- If API encryption is enabled (ESPHome's default), you'll need the `api:
  encryption: key:` value from the device's own ESPHome YAML source — this has
  nothing to do with the old HA instance, it's baked into the device's firmware.

Once added, it shows up as a `media_player` entity (for TTS playback) and an
`assist_satellite` entity, usable directly in the Assist pipeline above.

**A `tts.speak` gotcha worth knowing**: the "Media player entity" field in the
Developer Tools → Actions UI for `tts.speak` is a *data* parameter (where to play
the audio), not the action's *target* (which TTS entity to invoke). If you fill in
the media player but nothing else, you'll get `must contain at least one of
entity_id, device_id, area_id, floor_id, label_id` — you also need to click **+ Add
target** and select the TTS entity itself (e.g. `tts.silero_tts_enhanced`)
separately.

## Operational notes

- **If the host's network configuration changes** (new Wi-Fi network, new IP, moved
  to a different subnet/VLAN — e.g. to reach a satellite on a different segment),
  restart the `homeassistant` container afterward: `sudo docker compose restart
  homeassistant`. Because it runs with `network_mode: host`, HA's mDNS/zeroconf
  discovery binds directly to host interfaces and can be left in a stale state by
  a live network change underneath it, causing general instability until restarted.

## What's deliberately not here yet

- `VoiceActivityDetection` container (Milestone 3).
- `LargeLanguageModelConnector` / LiteLLM proxy (Milestone 2) — OpenRouter is
  wired in directly for now, exactly as designed for this milestone.
- Tier B (post-MVP).
