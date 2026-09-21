"""Give Assist satellites a wake word pre-roll buffer.

When wake word detection runs in Home Assistant (satellite streams continuously,
a Wyoming wake word service detects), the detector only fires *after* the wake
word ended plus its own latency (measured 30-450 ms for openWakeWord). Anything
the user says in that gap is consumed by the detector and never reaches speech
recognition, so a command spoken in one breath loses its first word.

Home Assistant already has a fix -- `WakeWordSettings.audio_seconds_to_buffer`
keeps the last N seconds of audio and forwards it to STT after detection -- but
only the websocket API (browser) sets it. Satellites (`assist_satellite`, used
by ESPHome and Wyoming) never pass wake word settings, so they get the
dataclass default of 0 s.

This changes that default. It is a deliberate, small monkeypatch of an HA
internal (`assist_pipeline.pipeline.WakeWordSettings`); if a future HA release
moves or renames it, setup logs an error and does nothing rather than
breaking Assist. Callers that pass explicit settings (the websocket API) are
unaffected.

Configuration (configuration.yaml):

    assist_preroll:
      seconds: 0.2    # optional, default 0.2

Too small drops the first word; too large lets the tail of the wake word leak
into the transcript. It has to cover the detector's latency but stay shorter
than the wake word itself.
"""

from __future__ import annotations

import dataclasses
import logging

import voluptuous as vol

from homeassistant.components.assist_pipeline import pipeline
from homeassistant.core import HomeAssistant
from homeassistant.helpers.typing import ConfigType

DOMAIN = "assist_preroll"
CONF_SECONDS = "seconds"
DEFAULT_SECONDS = 0.2
# Attribute on the patched class holding the original, so re-running setup
# (e.g. a config reload) patches the original rather than stacking subclasses.
_ORIGINAL_ATTR = "_assist_preroll_original"

_LOGGER = logging.getLogger(__name__)

CONFIG_SCHEMA = vol.Schema(
    {
        DOMAIN: vol.Schema(
            {
                vol.Optional(CONF_SECONDS, default=DEFAULT_SECONDS): vol.All(
                    vol.Coerce(float), vol.Range(min=0, max=2)
                )
            }
        )
    },
    extra=vol.ALLOW_EXTRA,
)


async def async_setup(hass: HomeAssistant, config: ConfigType) -> bool:
    """Patch the default wake word settings used by satellites."""
    seconds: float = config[DOMAIN][CONF_SECONDS]

    current = getattr(pipeline, "WakeWordSettings", None)
    if current is None or "audio_seconds_to_buffer" not in getattr(
        current, "__dataclass_fields__", {}
    ):
        _LOGGER.error(
            "assist_pipeline.pipeline.WakeWordSettings.audio_seconds_to_buffer "
            "not found (Home Assistant changed?); pre-roll NOT applied"
        )
        return True

    original = getattr(current, _ORIGINAL_ATTR, current)
    patched = dataclasses.make_dataclass(
        original.__name__,
        [("audio_seconds_to_buffer", float, dataclasses.field(default=seconds))],
        bases=(original,),
        frozen=True,
    )
    setattr(patched, _ORIGINAL_ATTR, original)
    # PipelineRun.wake_word_detection() resolves `WakeWordSettings()` from this
    # module's globals at call time whenever the caller passed no settings.
    pipeline.WakeWordSettings = patched
    _LOGGER.info("Wake word pre-roll for satellites set to %.2f s", seconds)
    return True
