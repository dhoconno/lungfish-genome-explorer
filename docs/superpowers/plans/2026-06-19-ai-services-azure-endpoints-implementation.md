# AI Services Azure Endpoints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update AI Services model selections to current provider API models and add an advanced Azure-hosted OpenAI endpoint path for the app and CLI.

**Architecture:** Keep direct provider preferences as the primary path. Add a Core `OpenAIEndpointConfiguration` that builds direct OpenAI or Azure OpenAI request URLs, auth headers, effective model IDs, and non-secret metadata. Store Azure settings in `AppSettings`, expose them as advanced controls in the settings tab, and pass the configuration into existing OpenAI provider creation points. Add CLI flags/env resolution for Azure OpenAI so scientific AI haplotyping provenance captures endpoint/deployment/API version without secrets.

**Tech Stack:** Swift Package Manager, SwiftUI settings UI, Core AI provider services, ArgumentParser CLI, XCTest.

---

## Baseline

- `swift test --filter AIProviderTests` currently fails to compile in this worktree before Azure changes because `AIHaplotypingRunner` passes `reasoningEffort` to `AIStructuredRequest`, but the Core request type lacks that initializer/property.
- Treat the compile failure as a pre-existing interface drift and repair it as part of the provider path before validating the Azure work.

## Steps

- [ ] Add failing Core provider tests for Azure OpenAI URL construction, `api-key` auth, model/deployment handling, metadata, and `reasoningEffort` request preservation.
- [ ] Add failing AppSettings tests for new Azure fields, defaults, snapshot round-tripping, section reset, and updated direct-provider model defaults.
- [ ] Add failing CLI tests for `AZURE_OPENAI_*` environment resolution, explicit Azure flags, preview command output, and provenance-safe resolved options.
- [ ] Add `OpenAIEndpointConfiguration` in Core and update `OpenAIProvider` to use it for chat completions and structured requests.
- [ ] Add `reasoningEffort` to `AIStructuredRequest` and make OpenAI structured requests use Responses API when direct OpenAI reasoning is requested; keep Azure on Azure chat-completions unless the endpoint mode explicitly supports Responses later.
- [ ] Add AppSettings fields and a helper for producing an OpenAI endpoint configuration.
- [ ] Update AI Services settings UI model menus and advanced Azure controls.
- [ ] Wire Azure configuration into `AIAssistantService`, genotype AI execution, and CLI provider creation.
- [ ] Ensure AI haplotyping command previews and provenance-facing explicit/resolved/default option dictionaries include non-secret Azure endpoint/deployment/API version data.
- [ ] Run focused tests: `AIProviderTests`, `AppSettingsTests`, `AISettingsIntegrationTests`, `GenotypeSubcommandsTests`, and AI haplotyping provenance/publisher tests touched by the CLI/app metadata changes.
