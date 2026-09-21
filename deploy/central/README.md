# Central stack — MVP Milestones 1–2

**Milestone 1: verified working end-to-end** on real hardware — wake word (local, ESPHome
ReSpeaker satellite) → STT (Vosk/Wyoming) → OpenRouter LLM (conversation agent) →
TTS (Silero) → spoken response, actually heard out of the ReSpeaker's speaker.

**Milestone 2 (LiteLLM proxy in front of OpenRouter): proxy verified, HA switch-over
pending** — the proxy itself is running and tested (chat, and tool calls both
streaming and non-streaming); see [Conversation agent — via LiteLLM](#conversation-agent--via-litellm).

Brings up the central pieces from [Milestone 1](../../architecture/README.md#milestone-1--core-pipeline-on-device-wake-word--vad-direct-openrouter):
Home Assistant Core, `SpeechToTextEngine` (Vosk over Wyoming), and `TextToSpeechEngine`
(Silero, via [indevor/silero-tts-enhanced-addon](https://github.com/indevor/silero-tts-enhanced-addon) +
its [HACS companion integration](https://github.com/indevor/silero-tts-enhanced-hacs)).
Milestone 2 adds the `LargeLanguageModelConnector` (`llm-connector`, a LiteLLM proxy).
No `VoiceActivityDetection` container yet — that's Milestone 3.

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

**Quick start on a fresh machine**: clone this repo yourself, then run `init.sh`
to install Docker and bring up the stack in one go:

```bash
git clone https://github.com/Eaglegor/Hass.git
bash Hass/deploy/central/init.sh
```

It only handles what can actually be scripted — the HA onboarding, HACS,
and integration setup below are still manual, UI-driven steps (the script
prints a checklist of them at the end).

## Prerequisites

- Docker Engine + Compose plugin installed (`docker compose version` should work).
- At least one Tier A voice satellite (e.g. an ESP32 device running ESPHome's
  `voice_assistant` component with local wake word) — this stack has nothing to
  say to a microphone by itself.
- An OpenRouter API key (`init.sh` prompts for it; otherwise set `OPENROUTER_API_KEY` in `.env`).

## Bring it up

```bash
cd deploy/central
cp .env.example .env
# fill in OPENROUTER_API_KEY, LITELLM_MASTER_KEY (any random `sk-...` string) and
# MATTER_PRIMARY_INTERFACE; edit anything else if you want a different Vosk model/language
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
   plain custom integrations need it explicitly). `init.sh` already does this
   part for you; skip straight to the hard-refresh/Add Integration step below
   if you used it. Otherwise:
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

### Conversation agent — via LiteLLM

The `llm-connector` container is a [LiteLLM](https://docs.litellm.ai/) proxy
listening on `127.0.0.1:4000` (loopback only — HA's host networking reaches it
there; nothing else on the LAN needs to). It sits between HA's conversation
agent and OpenRouter, so the LLM provider can change without touching HA:

- HA only ever asks for the model **alias** `assistant`.
- `config/litellm/config.yaml` maps that alias to a real provider/model
  (currently `openrouter/google/gemini-3.5-flash-lite`).
- **To change the model or provider later**: edit `litellm_params` in that file
  (the file has commented examples for a direct Anthropic key, a local Ollama
  model, and load-balancing/failover between entries sharing one alias), then
  `docker compose restart llm-connector`. Nothing changes on the HA side.
  Extra provider API keys go in `.env` *and* in `llm-connector`'s
  `environment:` in `docker-compose.yml`.

Wire HA to it:

1. Settings → Devices & Services → Add Integration → **LiteLLM** (built into HA,
   no HACS needed).
2. URL `http://localhost:4000`; API key = `LITELLM_MASTER_KEY` from `.env`.
3. On the new entry, **Add conversation agent**: pick the `assistant` model
   (the list comes straight from the proxy's `/v1/models`) and enable
   **Control Home Assistant → Assist** so it can operate devices. The system
   prompt/persona is set in this agent's own **Prompt** field in the HA UI — it
   is deliberately not kept in this repo, so re-enter it by hand after a rebuild.
4. Switch the Assist pipeline's conversation agent to it (next section).

Quick sanity check of the proxy independent of HA:

```bash
set -a; . ./.env; set +a
curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model":"assistant","messages":[{"role":"user","content":"ping"}]}'
```

The image is pinned to a version (`v1.102.0`) rather than a floating tag on
purpose — LiteLLM's tool-calling layer has had upstream regressions (see the
architecture doc's research), so bump it deliberately and re-run a tool-call
check afterwards.

**Verified at pin time (2026-09-21)** against `assistant` →
`google/gemini-3.5-flash-lite` on OpenRouter: plain chat, a tool call
non-streaming, a tool call streaming, streaming a turn with *both* text and a
tool call (the [BerriAI/litellm#17246](https://github.com/BerriAI/litellm/issues/17246)
scenario — worked), and a tool-result follow-up round trip. Not yet verified:
HA's own Assist tool calls end to end through the `litellm` integration (the
probes used up to 15 synthetic function tools, not HA's real tool set).

#### Web search

HA's `litellm` integration can't enable provider-side search (it only sends the
function tools Assist exposes), so `config.yaml` does it at the proxy instead:
`model_info.extra_tools` on the `assistant` deployment lists tools that
`custom_callbacks.py` **appends** to each request going to that deployment. It's
currently OpenRouter's `openrouter:web_search` with `engine: native` — exactly
what HA's old `open_router` agent used (`web_search: tool_native`). The model
decides per request whether to search, so ordinary commands ("turn on the
light") don't pay for it: in testing, a device command took ~2.4s with 15 tools
and no search, a simple question 0.6s, and a live-data question (weather, FX
rate) ~2s with a citation.

- **Turn it off / change it** by deleting or editing that `extra_tools` block,
  then `docker compose restart llm-connector`. Other OpenRouter engines
  (`exa`, `firecrawl`, `perplexity`, …) only differ in `parameters.engine`.
- **Why a hook and not `litellm_params.extra_body.tools`:** `extra_body` *replaces*
  the request's `tools` instead of adding to them — confirmed by inspecting the
  request LiteLLM actually sends upstream — so HA's device-control tools would
  silently vanish.
- **It's per deployment, not per alias**, so if one alias fails over between
  providers, each backend only receives its own search tool (OpenRouter's tool
  never reaches a direct Anthropic key, which would use Anthropic's own
  `web_search_20250305` — see the commented example in `config.yaml`).
- **Switching to a model with no native search** (e.g. a local Ollama model)
  needs a different approach — an HA-side search tool script backed by SearXNG
  or a search API — since nothing at the proxy can give such a model search for
  free. LiteLLM has a `websearch_interception` feature, but it only converts a
  search tool the *client* sends, and HA's integration never sends one.

### Assist pipeline

Settings → Voice assistants → add a pipeline using the Wyoming STT you just
added, the LiteLLM conversation agent from the previous step, and the Silero TTS
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

- **RTL8821CE Wi-Fi/Bluetooth combo chip floods dmesg with "failed to send h2c
  command"** once Bluetooth is active (common on N150 mini PCs) — this is a
  known `rtw88` driver bug (LPS deep-sleep mode conflicting with Bluetooth
  coexistence), not harmless noise: per an
  [LKML report on this exact chip](https://lkml.iu.edu/2603.2/04736.html), it
  can escalate to a **hard system freeze** when combined with PCIe ASPM.
  `init.sh` writes `/etc/modprobe.d/rtw88-h2c-fix.conf`
  (`disable_lps_deep=Y`, `disable_aspm=Y`) to work around it — this requires
  a **reboot** to take effect, since it doesn't apply to an already-loaded
  module. If you ever see this log spam (or unexplained WiFi/Bluetooth
  freezes) on a machine you didn't run `init.sh` on, or before rebooting
  after running it, this is why.
- **`matter-server` logs "Failed to advertise records: ... Network is unreachable"
  for `br-xxxxxxxx`** — this is expected noise, not a sign `MATTER_PRIMARY_INTERFACE`
  didn't take effect. `--primary-interface` only picks which interface's address
  matter-server advertises as its own; the underlying `zeroconf` library still
  enumerates *every* interface on the host (since it's `network_mode: host`),
  including the Docker bridge network `docker compose` creates for `stt`/`tts`,
  and logs a harmless error when it can't bind/multicast on that unrelated
  bridge. Widely reported upstream with no available fix (there's no flag to
  restrict which interfaces zeroconf binds to) — see
  [home-assistant/core#145481](https://github.com/home-assistant/core/issues/145481)
  and [home-assistant/core#149284](https://github.com/home-assistant/core/issues/149284),
  where devices commission and work fine despite it. Confirm by actually adding
  the Matter integration (`ws://localhost:5580/ws`) and commissioning a device —
  if that works, ignore the log line.
- **`matter-server` can hang forever at "Fetching the latest vendor info from
  DCL"** — confirmed on real hardware, not just a slow-DCL edge case. Both the
  PAA-certificate fetch and the vendor-info fetch hit `on.dcl.csa-iot.org` on
  every startup, but only the PAA-cert code catches its own timeout and falls
  back to a Git mirror; `vendor_info.py`'s fetch only catches
  `aiohttp.ClientError`, not `TimeoutError`, so a stalled connection there is
  never handled and blocks the server from ever finishing startup (matches
  [home-assistant/core#167227](https://github.com/home-assistant/core/issues/167227),
  an unresolved upstream report of the identical hang). Worked around in
  `docker-compose.yml` via `extra_hosts` pointing that hostname at loopback,
  so the connection refuses instantly and both fetches take their existing
  fallback paths immediately instead of stalling. Costs only DCL's live data
  freshness (vendor names may show as bare vendor IDs instead of friendly
  names; PAA certs still come from the Git mirror either way).
- **DNS stability for `homeassistant`/`matter-server`** — Docker only writes a
  host-networked container's `/etc/resolv.conf` once, at creation; it's never
  kept in sync afterward. Pointing it at a *dynamic* nameserver IP (what
  `dhcpcd` puts there directly, e.g. `nameserver 10.0.0.1`) means that
  snapshot goes stale the moment the real upstream server changes — including
  across a plain reboot, since `restart: unless-stopped` restarts the
  existing container rather than recreating it (confirmed on real hardware:
  the snapshot can end up loopback-pointing, e.g. `nameserver ::1`/
  `127.0.0.1`, from whenever the container happened to first be created, and
  then just persists, breaking outbound DNS to OpenRouter/DCL/etc. on every
  boot since). Recreating the containers on every boot to paper over this was
  considered and rejected — it's still a race against `dhcpcd` at boot, and
  treats the symptom rather than the cause.

  The actual fix, which `init.sh` sets up: install and enable
  **`systemd-resolved`**, and point `/etc/resolv.conf` at its stub listener
  (`127.0.0.53`) instead of a raw DHCP-assigned IP. That address is fixed —
  it never changes across reboots or network switches — while
  `systemd-resolved` itself gets fed the real upstream nameserver dynamically
  by `dhcpcd`'s built-in hook. So a container's one-time DNS snapshot says
  "ask 127.0.0.53" forever, and that's always correct, regardless of what the
  actual upstream server is at any given moment. `init.sh` is idempotent here
  (safe to rerun) and also removes any leftover `hass-dns-refresh.service`
  from an earlier version of this script that tried the recreate-on-boot
  approach.

  **Expect `init.sh`'s own verification step to fail the very first time you
  run this** (it'll warn "DNS isn't resolving through systemd-resolved's stub
  yet" and things depending on DNS, like the `tts` image's git build context,
  will fail right after) — confirmed on real hardware, and it's a one-time
  bootstrap ordering quirk, not a bug: `dhcpcd` only pushes the upstream
  nameserver to `systemd-resolved` via its hook when it acquires or renews a
  lease, and if you already had a lease from *before* `systemd-resolved`
  existed, there's no lease event left to trigger that hook. A single reboot
  fixes it permanently, because every subsequent boot starts
  `systemd-resolved` first and *then* has `dhcpcd` acquire a fresh lease,
  firing the hook in the correct order. If it's still not working after a
  reboot, check `resolvectl status` and `systemctl status systemd-resolved` —
  there's a separate, known rough edge between `dhcpcd`'s traditional
  resolvconf hook and systemd's `resolvectl`-based resolvconf shim.
  `init.sh` backs up the previous `/etc/resolv.conf` to
  `/etc/resolv.conf.pre-systemd-resolved.bak` before switching, so you can
  roll back with `sudo ln -sf /etc/resolv.conf.pre-systemd-resolved.bak
  /etc/resolv.conf` if needed.

## What's deliberately not here yet

- `VoiceActivityDetection` container (Milestone 3).
- Tier B (post-MVP).
