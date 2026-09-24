---
title: The AI Assistant
chapter_id: appendices/ai-assistant
audience: bench-scientist
prereqs: [01-foundations/06-the-lungfish-project]
estimated_reading_min: 14
task: Open the Inspector's Assistant tab, connect a bring-your-own-key provider, and ask questions about the dataset that is open.
tags: [ai-assistant, reference, byo-key, help]
tools: []
entry_points:
  - "View > AI Assistant"
shots:
  - id: ai-assistant-panel
    caption: "The Assistant tab of the Inspector beside a dataset viewport, showing the welcome message, the suggested-question buttons, and the Data sent and Clear buttons in its header."
  - id: ai-assistant-provider-setup
    caption: "The AI Services settings tab with the Enable AI-powered search toggle, the Default provider picker, and one provider's API Key field, key-status indicator, and Model picker."
  - id: ai-assistant-azure-endpoint
    caption: "The Azure AI section of the AI Services settings tab, with the Use Azure AI-hosted endpoint toggle and the Endpoint and Deployment fields."
illustrations: []
glossary_refs: [ai-assistant, api-key, keychain, provenance, checksum, inspector, bundle, viewport, table-drawer, operations-panel, grounded-answer, provider-fallback, contig]
features_refs: [ai.assistant]
fixtures_refs: [demo-project]
brand_reviewed: false
lead_approved: false
---

## What it is

The [AI Assistant](../../GLOSSARY.md#ai-assistant) is a chat tab in Lungfish Genome Explorer (LGE) that answers questions about the dataset you have open. It lives in the [Inspector](../../GLOSSARY.md#inspector), the pane on the right of the project window. You type a plain question such as "what is in this bundle?" and read the reply in the tab.

The assistant gathers the state of the active [viewport](../../GLOSSARY.md#viewport), the large display in the middle of the window. That state is the loaded [bundle](../../GLOSSARY.md#bundle), the organism, the region on screen, and any rows you selected in the Variants or Samples tables. The rows appear on the **Variants** tab of the [table drawer](../../GLOSSARY.md#table-drawer), which [Reading the Variants Table](../05-variants/02-reading-the-variant-browser.md#what-it-is) covers. Gathering that state is what lets an answer refer to what is in front of you.

This is a bring-your-own-key feature. LGE includes no language model and runs none. You hold an account with a company that serves a large language model, a program trained on text that writes text in reply, and you give LGE the [API key](../../GLOSSARY.md#api-key) for that account. An API key is a long secret string that identifies your account to a service, the way a password identifies you to a website. Every question travels to that company under your key, is billed to your account, and is answered by their model rather than by anything on your Mac.

Two consequences matter more than any feature below. First, your data leaves your machine. The context the assistant assembles, including bundle names, sample names, and selected variant rows, goes to the provider you configured. Second, a reply is generated text, not a computed result. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. Nothing the assistant says enters that record. Use the assistant to orient yourself, and confirm anything you intend to publish in the viewport, in the Operations Panel, or on the command line.

<!-- SHOT: ai-assistant-panel -->

## Why you would do this

The assistant helps most when you open a project someone else built. The project's folders are described in [A tour of the sidebar](../01-foundations/06-the-lungfish-project.md#a-tour-of-the-sidebar), but the sidebar alone does not say which chromosomes a reference holds, how many variants sit in its variant track, or how those variants break down by type.

Those questions are lookups against data already loaded, and the assistant can run the lookups, read the answers, and put them into a sentence. A question such as "is this variant pathogenic?" is not a lookup, and the assistant answers it from the model's general reading rather than from your project. It is weakest when a question needs data that is not loaded, and most useful when it explains a result you are looking at.

## Before you start

Nothing else in this manual depends on this appendix, and no analysis in LGE needs an AI provider.

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. The examples use the demo project and its HG002 chromosome 20 slice, a 500,000-base region of chromosome 20 from HG002, a widely studied human reference sample, which [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains how to build.

The Assistant tab appears only while the viewport shows a reference sequence or another genomics view such as a multiple sequence alignment, for example the HG002 chromosome 20 slice under `Reference Sequences/`. Reads, assemblies, mapping results, classifier results, and genotype results open an Inspector without it, and nothing explains the absence.

You also need an account and a key from Anthropic, OpenAI, or Google Gemini. You create the account on the provider's own website, which issues the key and asks for payment details. Each provider charges per question at its own rates, so check their prices before you decide how much to ask. Once the setting in step 2 is on, the tab opens and shows its suggested questions even with no key, but every question then comes back saying the API key is not configured and pointing you at **Settings > AI Services**.

Allow about twenty minutes, most of it spent creating the provider account.

## Procedure

### Step 1. Open the AI Services settings tab

Choose **Settings...** (Cmd-,) from the application menu, the menu named after the app at the left of the menu bar, and click **AI Services**. Leave it open for the next two steps.

### Step 2. Turn on AI search

Turn on the toggle at the top of the tab, labelled `Enable AI-powered search`. It is off on a new installation, and turning it on sends nothing, because no question has been asked yet. While it is off, the Assistant tab is hidden and **View > AI Assistant** raises an alert headed "AI Assistant Disabled".

### Step 3. Choose a default provider and enter its key

Choose a company from the `Default provider:` picker, whose options read "Anthropic Claude", "OpenAI", and "Google Gemini". Find the section for that company further down the tab and type or paste your key into its **API Key** field. The grey placeholder text shows the shape each company's keys take, `sk-ant-...` for Anthropic, `sk-...` for OpenAI, and `AIza...` for Google Gemini, and the prefix is already part of the key the provider gives you.

Type the key only into that field. LGE writes it into the macOS [Keychain](../../GLOSSARY.md#keychain), the system store that holds passwords under the protection of your login, and never into your project folder, so a colleague who receives your project does not receive your key. The key saves as you type, and "Saving API key changes to Keychain…" appears under the form while it is written.

An indicator to the left of each key field reports what LGE knows about that key, and it is your only confirmation.

| Indicator | Meaning |
|---|---|
| Grey minus sign | The field is empty. |
| Orange hourglass | A key is entered but not yet checked, or is being checked, with the caption "Validating API key and quota...". |
| Green checkmark | The provider accepted the key, with the caption "Key is valid and ready for AI queries." |
| Red cross | The check failed, with a caption naming the reason. |

You may fill in more than one provider. LGE tries your default first and falls back to the others when it cannot answer, which [Settings](#settings) explains.

<!-- SHOT: ai-assistant-provider-setup -->

### Step 4. Open the Assistant tab

Click the HG002 chromosome 20 slice under `Reference Sequences/` in the sidebar, then choose **View > AI Assistant** (Cmd-Shift-A). The Inspector opens with its **Assistant** tab selected. The header carries the title, a status line, a **Data sent…** button, and a **Clear** button.

The tab greets you with a welcome message and a column of suggested questions written for whatever is loaded. With the HG002 chromosome 20 slice open they include "Data overview", "Explore current view", "Search for a gene", "Find related research", and "Chromosome guide", and "Variant statistics" when a variant track is loaded. The research button searches PubMed, the free index of biomedical literature kept by the National Library of Medicine. Click a button to send its question. With no bundle loaded there is one suggestion, which asks how to load a bundle.

### Step 5. Read what would be sent

Click **Data sent…**. A popover shows what a request would carry and which companies could receive it. Opening it sends nothing.

The popover names the fallback order and states that only providers whose keys passed the check in step 3 are used. It also warns that one question can reach two companies, because a request that fails at the first provider may already have arrived there before the second receives it. Below that it prints the current context in full, including the bundle name, the organism, and the region. Read it before your first question and again whenever you switch to data you would rather not send.

### Step 6. Ask a question

Click the field at the bottom of the tab, which reads "Ask about your genome data...", type a question, and press Return. An indicator spins while the provider works, usually for a few seconds. Each request to a provider times out after 150 seconds. LGE then tries the next provider, and reports a failure only when none is left.

For the demo project, try "How many variants are in the HG002 chromosome 20 slice, and which chromosomes does it contain?" Once you have clicked a row in the Variants tab, "What are the variants I have selected?" works too.

The reply arrives as a message with a copy button. This appendix quotes no reply, because the text comes from a model outside LGE and differs between providers, models, and two runs of the same question. Ask one question at a time. A second question sent while one is in flight gets "Please wait for the current request to complete."

### Step 7. Clear the conversation when you change datasets

Click **Clear**. The messages disappear, the welcome message returns, and the suggested questions are rebuilt for whatever is loaded now. Clearing writes nothing to your project and cannot unsend anything that already went to a provider. Clear whenever you move to a different bundle, so the assistant does not reason from a conversation about the previous one.

## Settings

Every control below lives in **Settings > AI Services**. **Restore Defaults** at the foot of the tab returns every AI setting to the values described here, including turning AI search off, and leaves your keys in the Keychain.

**`Enable AI-powered search`.** Turns the AI Assistant on and adds its tab to the Inspector. The default is off, so a new installation sends nothing until you choose otherwise. Turn it on once you have a key, and turn it off whenever you work on data that must not leave the machine. This setting has no command-line flag.

**Default provider:.** Chooses which company is tried first, from "Anthropic Claude", "OpenAI", and "Google Gemini". The default is "Anthropic Claude". Change it when your account or your lab's agreement is with another company. LGE then tries the other two in the fixed order Anthropic, OpenAI, Google Gemini with your default removed, so choosing "OpenAI" gives OpenAI, then Anthropic, then Google Gemini. A provider with an empty key field, or with a key that failed its check, is skipped. This setting has no command-line flag.

**API Key.** Holds your key for the provider whose section it sits in, with one field each under **Anthropic**, **OpenAI**, and **Google Gemini**. Each field starts empty. Fill in your default provider's, and a second only if you want the fallback to have somewhere to go. The key is stored in the Keychain, so it survives a restart and never enters your project folder. This setting has no command-line flag.

**Model:.** Chooses which of the company's models answers, with one picker per provider section. The default is the entry marked Recommended, which is Claude Sonnet 4.6 for Anthropic, GPT-5.5 for OpenAI, and Gemini 3.5 Flash for Google Gemini, each chosen to balance speed against quality in a chat panel. If the picker shows your saved value as a Custom entry, LGE no longer lists that model, so pick a listed one. This setting has no command-line flag.

**Use Azure AI-hosted endpoint.** Sends the OpenAI requests to a model your organisation runs on Microsoft's Azure cloud instead of to OpenAI, which lets a lab with a Microsoft agreement use the assistant without an OpenAI account. The default is off. Turn it on only when an administrator has given you an address and a deployment name, and fill in the two fields below first. This setting has no command-line flag.

**Endpoint.** Holds the web address your Azure administrator gives you, shaped like the placeholder `https://example.openai.azure.com`. It starts empty. It has no effect while the Azure toggle is off. This setting has no command-line flag.

**Deployment.** Holds the deployment name your Azure administrator gives you, a label your organisation chose that is not always the model's own name. It starts empty, with `gpt-5-mini` as placeholder text. Change it when your administrator publishes a new deployment. This setting has no command-line flag.

<!-- SHOT: ai-assistant-azure-endpoint -->

**Clear All Keys.** Removes all three provider keys from the Keychain at once. Use it when you hand the Mac on, when a key has been exposed, for example pasted into a shared document, or when you want to be certain nothing can be sent. LGE first asks "Clear All API Keys?" and warns that you will need to enter the keys again. There is no undo. This setting has no command-line flag.

## Reading the results

A reply is one message in the Assistant tab. Its value depends on whether it was a [grounded answer](../../GLOSSARY.md#grounded-answer), meaning based on a real lookup in your data rather than on the model's recollection. Two signs tell you.

The first is the status line in the header, which reports what the assistant is doing, such as "Searching genes...", "Reading variant table...", or "Listing chromosomes...". A question answered from your data shows one of these before the reply appears.

The second is the reply itself. An answer that names your bundle, your chromosome, and counts that match the Variants tab was grounded. An answer that describes a gene in general terms without naming anything from your project probably was not, and is worth asking again more specifically.

The assistant can run these lookups:

- Search genes and variants, and report the details of one named gene.
- Report variant statistics, and read the selected or visible rows of the Variants and Samples tables.
- Report what the viewport is showing, and list the chromosomes or [contigs](../../GLOSSARY.md#contig) in the loaded reference with their sizes.
- Search PubMed for papers. The search terms go to NCBI, which the **Data sent…** popover does not list.
- Move the view to a gene or to a region you name, the only change it can make anywhere in LGE.

It works in rounds, running lookups and reading the answers before it replies, and it stops after eight rounds. A single clear question usually takes one or two. Some replies come from LGE rather than the model. Two you may meet are these. "No configured AI provider has a valid API key with available credits." means no key passed its check, which is a settings problem. A reply beginning "I reached the maximum analysis steps without a final text response" means the eight rounds ran out before the model wrote any answer, so split the question into parts.

When a gene, variant, or region comes up, the assistant also suggests wet-lab follow-ups such as assays and reagents, shaped by the loaded organism, with separate guidance for rhesus macaque, human, and mouse. This cannot be turned off. Treat every reagent it names as a lead to check against the vendor's datasheet and current literature, never as a validated choice.

## What good looks like

Four checks separate a reply you can act on from one to set aside.

1. The numbers match the app. Compare a variant count with the Variants tab, which is the correct count.
2. The answer names your data, meaning your bundle, your organism, and your coordinates.
3. You read **Data sent…** before sending anything sensitive, since it is the only way to see what a question discloses.
4. Nothing changed. The assistant edits no files, runs no workflow, imports or deletes no bundles, and writes nothing into your project's provenance. If a bundle looks different after a conversation, the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P), shows what changed it.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](cli-reference.md#finding-the-program) shows how to run it.

The AI Assistant has no command-line counterpart. No `lungfish-cli` command opens a chat or sends a question to a provider. `lungfish-cli search` looks for a text pattern in a FASTA file and involves no model. `lungfish-cli genotype ai-haplotyping` does call a model, for genotyping work, with its own provider flags listed in [CLI Reference](cli-reference.md).

## Next

Every other chapter of this manual works without an AI provider. Return to [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md) for how projects are organised.
