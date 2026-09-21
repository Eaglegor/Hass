"""LiteLLM proxy hooks for the LargeLanguageModelConnector.

Appends per-deployment "extra tools" from config.yaml to every request that goes
to that deployment. It exists for provider-side *server tools* -- tools the
provider itself executes, like OpenRouter's `openrouter:web_search` -- which
HA's `litellm` integration has no way to enable: it only ever sends the
function tools that HA's Assist API exposes.

Declare them next to the model they belong to, in config.yaml:

    model_list:
      - model_name: assistant
        litellm_params: {...}
        model_info:
          extra_tools:
            - type: openrouter:web_search
              parameters: {engine: native}

This can't be done with `litellm_params.extra_body.tools` instead: that
*replaces* the request's tools rather than adding to them, so HA's device-control
tools would silently disappear.

The hook runs after the router has picked a specific deployment, so if one alias
load-balances or fails over across providers, each backend only receives its
own `extra_tools` (e.g. OpenRouter's tool never reaches a direct Anthropic key).
"""

from typing import Any

from litellm.integrations.custom_logger import CustomLogger


class ExtraToolsInjector(CustomLogger):
    async def async_pre_call_deployment_hook(
        self, kwargs: dict[str, Any], call_type: Any
    ) -> dict[str, Any] | None:
        extra_tools = (kwargs.get("model_info") or {}).get("extra_tools")
        if not extra_tools:
            return None

        tools = list(kwargs.get("tools") or [])
        # The router may retry/fail over through this hook more than once for
        # one request -- don't stack duplicates.
        tools += [tool for tool in extra_tools if tool not in tools]
        kwargs["tools"] = tools
        return kwargs


extra_tools_injector = ExtraToolsInjector()
