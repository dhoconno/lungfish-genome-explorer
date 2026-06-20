# AI Services Azure Hosted Endpoint Design

Date: 2026-06-19

Status: Ready for user review

## Summary

Lungfish already exposes AI Services preferences for Anthropic, OpenAI, and
Google Gemini API keys and model selection. The current UI assumes first-party
provider endpoints. Many research environments instead route LLM traffic through
university or institutional Azure OpenAI or Azure AI Foundry deployments.

This design keeps the existing direct-provider preferences intact and adds an
advanced Azure-hosted OpenAI-compatible endpoint option for OpenAI. Direct
OpenAI remains the default. When the advanced Azure option is enabled, OpenAI
provider requests use the configured Azure endpoint, deployment name, and API
version. The deployment field is free text so institutions can use any deployed
model name exposed by their Azure resource, including names that differ from the
underlying model identifier.

The implementation also refreshes the built-in model menus for Anthropic,
OpenAI, and Gemini based on the current first-party API model lists as of
2026-06-19.

## Goals

- Keep first-party Anthropic, OpenAI, and Gemini settings as the normal default.
- Update model picker entries to current API models.
- Add an advanced OpenAI-hosted endpoint mode for Azure OpenAI and compatible
  Azure AI Foundry deployments.
- Support Azure endpoint and deployment values equivalent to:
  `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_DEPLOYMENT`,
  and `AZURE_OPENAI_API_KEY`.
- Reuse the existing OpenAI API key Keychain entry as the Azure API key when
  Azure mode is enabled.
- Preserve fallback ordering between configured providers.
- Record the actual endpoint, deployment/model value, credential
  source, and request status in provider attempt metadata.
- Ensure AI haplotyping and other scientific data-producing workflows preserve
  final-path provenance that names the hosted endpoint configuration used.

## Non-Goals

- Do not add generic custom endpoint support for Anthropic Bedrock, Anthropic
  Vertex AI, Gemini Vertex AI, or non-OpenAI-shaped model APIs in this slice.
- Do not implement Microsoft Entra ID authentication in this slice. API-key
  authentication is sufficient for the first Azure endpoint pass.
- Do not store API keys, Authorization headers, `api-key` headers, raw request
  bodies, or raw provider error bodies in provenance.
- Do not promise every Azure model catalog deployment will work. Deployments are
  supported when they expose the OpenAI-compatible chat or responses surface
  Lungfish uses.
- Do not turn hosted endpoint configuration into project-scoped scientific
  state. It remains a local user preference, with resolved runtime values
  copied into provenance when a scientific workflow runs.

## Current Context

The settings surface is `AIServicesSettingsTab`. It contains hardcoded model
pickers and stores API keys through `KeychainSecretStorage`. Non-secret settings
live in `AppSettings` and are persisted as one UserDefaults JSON blob.

The provider actors currently hardcode endpoint URLs:

- `OpenAIProvider`: `https://api.openai.com/v1/chat/completions` and
  `https://api.openai.com/v1/responses`
- `AnthropicProvider`: `https://api.anthropic.com/v1/messages`
- `GeminiProvider`: `https://generativelanguage.googleapis.com/v1beta/models/...`

The general AI Assistant resolves all three providers from settings and
Keychain. The structured AI haplotyping app flow currently resolves OpenAI or
Anthropic only. Structured provider responses already include
`AIProviderAttemptMetadata` with endpoint and API version fields, which is the
right place to preserve hosted endpoint identity for downstream provenance.

## Model Menu Update

Model menus remain curated defaults, not exhaustive provider catalogs. Each
picker should also preserve an already-saved custom value if it is not in the
current curated list, so existing users and Azure deployment names are not
silently reset.

### OpenAI

Use current text-capable API models that support function calling and structured
outputs for Lungfish use cases:

- `gpt-5.5` as the highest-capability default recommendation for complex work.
- `gpt-5.4`
- `gpt-5.4-mini`
- `gpt-5.4-nano`
- `gpt-5-mini`
- `gpt-5-nano`
- `gpt-4.1`
- `gpt-4.1-mini`

Keep support for existing saved values even if they are no longer shown as a
recommended option.

### Anthropic

Use current Claude API models:

- `claude-fable-5`
- `claude-opus-4-8`
- `claude-sonnet-4-6`
- `claude-haiku-4-5-20251001`

The direct Anthropic default should move from the retired Sonnet 4.5-era
selection to `claude-sonnet-4-6`, balancing quality and latency for normal app
queries. `claude-fable-5` remains available for highest-capability use.

### Gemini

Use current Gemini API text-output models:

- `gemini-3.5-flash`
- `gemini-3.1-pro-preview`
- `gemini-3-flash-preview`
- `gemini-3.1-flash-lite`
- `gemini-2.5-pro`
- `gemini-2.5-flash`
- `gemini-2.5-flash-lite`

The direct Gemini default should move to `gemini-3.5-flash`, with 2.5 models
kept as stable fallback choices for accounts or regions that have not enabled
the newer models.

## Azure Hosted Endpoint Mode

Add an advanced section under OpenAI named "Hosted OpenAI Endpoint" or similar.
The default state is disabled, which preserves current first-party OpenAI
behavior.

When enabled, settings expose:

- `openAIHostedEndpointEnabled`: boolean
- `openAIHostedEndpointKind`: `"azure"` for this slice
- `openAIHostedEndpoint`: base resource endpoint, for example
  `https://oc-aiservices.openai.azure.com`
- `openAIHostedDeployment`: free-text deployment/model name, for example
  `gpt-5-mini`

The deployment field is intentionally not constrained to the OpenAI picker.
Azure deployments can be named after the underlying model, a local project, a
university billing unit, or a Foundry deployment alias.

The OpenAI API key field continues to use `KeychainSecretStorage.openAIAPIKey`.
In Azure mode the label/help text should make clear that this key is the Azure
OpenAI API key for the configured endpoint.

## Request Routing

Introduce a small OpenAI endpoint configuration value type in LungfishCore, for
example `OpenAIEndpointConfiguration`.

The configuration should normalize:

- direct OpenAI chat URL: `https://api.openai.com/v1/chat/completions`
- direct OpenAI responses URL: `https://api.openai.com/v1/responses`
- Azure v1 chat URL:
  `<endpoint>/openai/v1/chat/completions`
- Azure v1 responses URL:
  `<endpoint>/openai/v1/responses`

Azure requests always use the v1 endpoint shape. The body `model` remains the
configured deployment name.

Authentication header behavior:

- Direct OpenAI: `Authorization: Bearer <key>`
- Azure API key: `api-key: <key>`

Request body behavior:

- Direct OpenAI: `model` is the selected OpenAI model.
- Azure hosted endpoint: `model` is the configured deployment name.
- Azure chat legacy URL also embeds the deployment name in the URL path.

Provider attempt metadata should record:

- provider: `"openai"`
- model: effective request model or deployment name
- endpoint: actual URL used, without secrets
- apiVersion: operation marker such as `responses.v1` or
  `chat.completions.v1`
- credentialSource: existing Keychain/environment source

## Settings Persistence

Extend `AppSettings.Snapshot` with the hosted endpoint fields. Decoding must
default missing fields so existing settings files load without migration
failure.

Resetting the AI Services section should:

- keep AI enabled/preferred-provider behavior consistent with current reset
  semantics;
- restore direct provider model defaults;
- disable hosted endpoint mode;
- clear hosted endpoint, deployment, and API-version overrides back to defaults.

Saving settings should trim endpoint/deployment/API-version whitespace and
reject malformed endpoint URLs at provider construction time rather than
silently building invalid requests.

## UI Behavior

The OpenAI section should remain usable without opening advanced options:

- API key field
- model picker
- normal validation status

The hosted endpoint controls should be visually secondary and collapsed or
clearly marked as advanced. They should not crowd the default user workflow.

When Azure mode is enabled:

- validation should use the Azure endpoint, deployment, API version, and OpenAI
  key field;
- model picker can remain visible as the direct OpenAI default, but the effective
  model should be shown as the deployment field;
- empty endpoint or deployment should mark validation as unverified or invalid
  with a specific message.

## CLI And Environment Follow-Up

The immediate preference work targets the app settings flow. The CLI currently
supports `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` for AI haplotyping. A follow-up
or same implementation pass should allow the CLI path to resolve:

- `AZURE_OPENAI_ENDPOINT`
- `AZURE_OPENAI_DEPLOYMENT`
- `AZURE_OPENAI_API_KEY`

When these are present for provider `openai`, the CLI should construct the same
hosted endpoint configuration and record the resolved hosted values in
provenance. If only `OPENAI_API_KEY` is set, direct OpenAI behavior remains
unchanged.

## Provenance Requirements

Hosted endpoints are especially important for reproducibility because the same
deployment name may point at different model versions across institutions or
over time. Scientific workflows that call AI providers must preserve:

- effective provider ID;
- effective deployment/model name;
- endpoint URL without credentials;
- API version;
- credential source without key material;
- provider attempt metadata;
- status code and sanitized error category;
- token usage when available.

The AI haplotyping GUI command preview should include non-secret hosted endpoint
values when Azure mode is enabled. Provenance must not contain API keys.

## Testing

Core provider tests should cover:

- direct OpenAI still calls first-party URLs and uses Bearer auth;
- Azure hosted chat requests call the Azure URL and use `api-key`;
- Azure hosted structured responses use deployment name in `model`;
- metadata records the actual endpoint and Azure API version;
- malformed hosted endpoint values fail with a clear provider error.

Settings tests should cover:

- new fields default correctly when old settings JSON is decoded;
- save/load round-trips hosted endpoint fields;
- AI Services reset disables hosted endpoint mode and restores defaults.

App/service tests should cover:

- AI Assistant provider resolution passes hosted endpoint config when enabled;
- AI haplotyping app execution passes hosted endpoint config and keeps direct
  provider fallback behavior otherwise.

CLI tests should cover:

- `AZURE_OPENAI_*` environment variables take precedence for OpenAI hosted mode;
- direct `OPENAI_API_KEY` behavior is unchanged when Azure variables are absent;
- provenance/resolved options include hosted endpoint and API version but not
  secrets.

## Rollout

The change is backward-compatible. Existing settings decode with hosted endpoint
mode disabled. Existing Keychain API keys remain in place. Direct provider model
defaults change to current model IDs, but saved custom selections continue to
round-trip.

The UI should make Azure hosting discoverable without making hosted deployment
configuration mandatory for normal users.
