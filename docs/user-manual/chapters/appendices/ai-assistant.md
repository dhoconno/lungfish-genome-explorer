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
glossary_refs: [ai-assistant, api-key, keychain, provenance, checksum, inspector, bundle, viewport, table-drawer, operations-panel, grounded-answer, provider-fallback, contig-reference, sequence-viewport, sidebar]
features_refs: [ai.assistant]
fixtures_refs: [hbb-gene]
brand_reviewed: false
lead_approved: false
---

## What it is

The [AI Assistant](../../GLOSSARY.md#ai-assistant) is a chat tab in Lungfish Genome Explorer (LGE) that answers questions about the dataset you have open. It lives in the [Inspector](../../GLOSSARY.md#inspector), the pane on the right of the project window. You type a plain question such as "what is in this bundle?" and read the reply in the tab.

When you send a question, the assistant gathers the state of the active [viewport](../../GLOSSARY.md#viewport), the large display in the middle of the window. That state is the loaded [bundle](../../GLOSSARY.md#bundle), the organism, the region on screen, and the first few rows shown in the Variants or Samples tables. The rows appear on the **Variants** tab of the [table drawer](../../GLOSSARY.md#table-drawer), the panel along the bottom of the viewport, which [Reading the Variants Table](../05-variants/02-reading-the-variant-browser.md#what-it-is) covers.

This is a bring-your-own-key feature, and LGE includes no language model. You hold an account with a company that serves a large language model, a program trained on text that writes text in reply, and you give LGE the [API key](../../GLOSSARY.md#api-key) for that account. An API key is a long secret string that identifies your account to a service, the way a password identifies you to a website. A paid chat plan is not such an account, because Anthropic and OpenAI each bill chat and API use separately ([Anthropic](https://support.claude.com/en/articles/9876003), [OpenAI](https://help.openai.com/en/articles/9039756)). Every question goes to the company under your key and is billed to your account.

Two consequences matter more than any feature below. First, your data leaves your machine, because the bundle names, sample names, and variant rows the assistant assembles go to the provider you configured. Second, a reply is generated text, not a computed result. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows. Nothing the assistant says enters that record, so confirm anything you intend to publish in the viewport, in the Operations Panel, or on the command line.

<!-- SHOT: ai-assistant-panel -->

## Why you would do this

The assistant helps most when you open a project someone else built. [A tour of the sidebar](../01-foundations/06-the-lungfish-project.md#a-tour-of-the-sidebar) describes the project's folders, but the sidebar alone does not say which chromosomes a reference holds, how many variants sit in its variant track, or how they break down by type.

Those are lookups against data already loaded, which the assistant can run and put into a sentence. A question such as "is this variant pathogenic?" is not a lookup, and the assistant answers it from the model's general reading rather than from your project.

## Before you start

Nothing else in this manual depends on this appendix, and no analysis in LGE needs an AI provider.

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. The examples use the Genes and Sequences demo project, which **Help > Demo Projects…** downloads, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. Its `NG_000007.3` reference bundle holds the human beta-globin (HBB) region with its genes drawn as features.

The Assistant tab shows in the Inspector's tab row only for sequence views such as a multiple sequence alignment. A reference bundle opened from `Reference Sequences/` lists no Assistant tab, though **View > AI Assistant** still opens the assistant pane there. Reads, mapping results under `Analyses/`, assemblies, classifier results, genotype results, and primer analyses open an Inspector without it.

You also need an account and an API key from Anthropic, OpenAI, or Google Gemini, made on the provider's own website.

- Anthropic's Claude Console makes one with **Create key** and shows it only once, so copy it at once ([page](https://platform.claude.com/docs/en/get-api-key)).
- OpenAI makes one in its dashboard ([quickstart](https://developers.openai.com/api/docs/quickstart)).
- Google makes one in Google AI Studio ([page](https://aistudio.google.com/docs/api-key)).

The OpenAI and Google pages do not say whether the key is shown again, so copy those keys when they appear too.

This appendix gives no price, because rates differ by model and change. Read the provider's pricing page before you ask many questions ([Anthropic](https://platform.claude.com/docs/en/about-claude/pricing), [OpenAI](https://developers.openai.com/api/docs/pricing), [Google](https://aistudio.google.com/docs/pricing)). Credits are money paid in advance, which each request draws down. A spend limit is a monthly ceiling on what the account may spend, after which requests are refused, and Anthropic's [rate-limits page](https://platform.claude.com/docs/en/api/rate-limits#setting-your-own-spend-limit) says you set it in its Console. Billing is the likely snag, since OpenAI's quickstart says to add credits and Anthropic's pricing page points to its Billing page to buy them. Checking a key sends a tiny test message, which costs a very small amount.

With AI search on but no key, every question comes back saying the API key is not configured.

## Procedure

### Open the AI Services settings tab

Choose **Settings…** (Cmd-comma) from the application menu, the menu named after the app, and click **AI Services**. The tab runs down through the sections Preferred Provider, Anthropic, OpenAI, Google Gemini, and Azure AI. Leave it open for the next two steps.

### Turn on AI search

Turn on **Enable AI-powered search** at the top of the tab. This one switch turns the Assistant on, so "AI-powered search" and "AI Assistant" name the same feature. While it is off, the Assistant tab is hidden and **View > AI Assistant** raises an alert headed "AI Assistant Disabled".

### Choose a default provider and enter its key

Choose a company from the **Default provider** picker, whose options read "Anthropic Claude", "OpenAI", and "Google Gemini". Find that company's section and paste the whole key, including its first characters, into its **API Key** field. The gray placeholder text shows how each company's keys begin, `sk-ant-...` for Anthropic, `sk-...` for OpenAI, and `AIza...` for Google Gemini. LGE checks a key only if it begins that way and holds at least 20 characters, except an OpenAI key while the Azure toggle is on, which is checked from 8 characters with any beginning.

LGE writes the key into the macOS [Keychain](../../GLOSSARY.md#keychain), the system store that holds passwords under the protection of your login, and never into your project folder. There is no Save button. The key saves as you paste or type it, and "Saving API key changes to Keychain…" appears under the form while it is written.

If the Keychain refuses the change, the form shows "Could not save API key changes to Keychain." and "Retry before using the new credentials." with a **Retry Saving Keys** button, which tries the write again. The check does not start until the save succeeds. If LGE cannot read the Keychain when the tab opens, the same place shows "Failed to retrieve secret from Keychain". If Retry fails again, ask whoever manages your Mac.

An icon to the left of each key field reports what LGE knows about that key.

| Icon | Meaning |
|---|---|
| Minus sign in a circle | The field is empty. |
| Hourglass in a circle | A key is entered but not yet checked, with the caption "Key entered. Enter a full key to validate automatically.", or is being checked, with the caption "Validating API key and quota...". |
| Checkmark in a filled circle | The provider accepted the key, with the caption "Key is valid and ready for AI queries." |
| Cross in a filled circle | The check failed, with a caption that opens with the words "Validation failed" and names the reason. |

A key counts as saved when "Saving API key changes to Keychain…" has gone and no "Could not save" message has replaced it, and as checked when the checkmark shows. The check starts by itself about half a second after you stop typing. Wait for the checkmark before you close Settings, because closing sooner keeps the key but cancels the check. LGE checks a key only when you change it, so a key you reopen later shows the hourglass until you edit it, which does not mean it is wrong.

If the hourglass stays with "Key entered", the key is too short or lacks its first characters, so paste it again whole. If it stays with "Validating API key and quota..." for long, check your internet connection and retype the key's last character, which restarts the check.

A mistyped or revoked key gets the cross, with "Validation failed" followed by "API key is not configured. Please add your API key in Settings > AI Services." LGE uses that wording when the provider answers that the key is not accepted, so make a new key and paste it whole. Any other refusal shows "HTTP error" and a status number, such as 403 for a Gemini key without access, followed by the provider's own words.

A used-up account also gets the cross. When OpenAI credits run out, an Anthropic spend limit is reached, or a Gemini daily quota (a cap on how much your key may use) is used, the caption goes on with "AI provider quota exceeded" and the provider's own words. That is a billing limit rather than a wrong key, so add credits or raise the limit on the provider's website.

One provider is enough. If you fill in more than one, LGE tries your default first and falls back to the others when it cannot answer, which [Settings](#settings) explains. Each extra provider needs its own account and billing.

<!-- SHOT: ai-assistant-provider-setup -->

### Open the Assistant tab

In the [sidebar](../../GLOSSARY.md#sidebar), the list of folders and results at the left of the window, click the reference bundle that holds your variant tracks under `Reference Sequences/`. For the demo, click `NG_000007.3`. Your variant rows then sit on the **Variants** tab of the table drawer, as [Reading the Variants Table](../05-variants/02-reading-the-variant-browser.md#open-the-variants-tab) shows. A reference bundle and a mapping result under `Analyses/` each open a viewport whose Inspector lists no Assistant tab.

Choose **View > AI Assistant** (Cmd-Opt-A). The Inspector shows the assistant pane, although its tab row lists no Assistant tab for a reference bundle, and the welcome message there reads "No genome bundle is currently loaded." The header carries the title, the status line of small gray text, a **Data sent…** button, and a **Clear** button.

The tab greets you with a welcome message and suggested questions written for what is loaded. With a reference sequence open they include "Data overview", "Explore current view", "Search for a gene", "Navigate to a gene", "Disease gene check", "Find related research", and "Chromosome guide". With a variant track, "Variant statistics", "Variants in this region", and "Variants in a gene" join them. The research button searches PubMed, the free index of biomedical papers. Click a button to send its question.

### Read what would be sent

Click **Data sent…**. A popover shows what a request would carry and which companies could receive it. Opening it sends nothing.

The popover names the fallback order and states that only providers whose keys passed the check are used. It warns that one question can reach two companies, because a request that fails at the first provider may already have arrived there. If that worries you, fill in only one key. Below that it prints the current context in full, including the bundle name, the organism, and the region. Read it before your first question and whenever you switch datasets.

If the data are human, or name patients or sample donors, ask the data owner or your institution's review office before you send a question.

### Ask a question

Click the field at the bottom of the tab, which reads "Ask about your genome data...", type a question, and press Return. A spinner row reading "Analyzing..." joins the conversation, and the header status line reads "Thinking..." and then names each lookup in turn. Short questions often come back within seconds, but the time depends on the provider and the model. The field and the send button are switched off until the reply arrives, and there is no Stop button.

Each request to a provider times out after 150 seconds. LGE then tries the next provider with a checked key, as it also does when a quota is used up, and the 150 seconds start again. When none is left, the panel shows the reason as a reply, which for a timeout begins "Network error" and ends "AI request timed out after 150 seconds." The failed question stays on screen but leaves LGE's memory of the conversation, so send it again. If the spinner is still turning many minutes later, quit LGE and open it again, which loses only the conversation.

For the `NG_000007.3` record, try "Which genes does this record hold, and where does HBB start and end?" You can check the reply against the ruler, the numbered position scale across the top of the [sequence viewport](../../GLOSSARY.md#sequence-viewport). For your own project, click a row in the Variants tab and ask "What are the variants I have selected?" Whether the assistant reads that row is the model's own choice.

The reply arrives as a message with a copy button. This appendix quotes no reply, because the text comes from a model outside LGE and differs between two runs of the same question.

### Clear the conversation when you change datasets

Click **Clear**. The messages disappear and the welcome message returns. Clearing writes nothing to your project and cannot unsend anything that already went to a provider. Clear whenever you move to a different bundle.

## Settings

Every control below lives in **Settings > AI Services**. None has a command-line flag, a typed option for the terminal, so you set each one in this tab. **Restore Defaults** at the foot of the tab returns every AI setting to the values described here and leaves your keys in the Keychain.

**Enable AI-powered search.** Turns the AI Assistant on and adds its tab to the Inspector. The default is off, so a new installation sends nothing. Turn it on once you have a key, and off whenever you work on data that must not leave the machine.

**Default provider.** Chooses which company is tried first, from "Anthropic Claude", "OpenAI", and "Google Gemini". The default is "Anthropic Claude". Change it when your account is with another company. LGE then tries the other two in the order Anthropic, OpenAI, Google Gemini, so choosing "OpenAI" gives OpenAI, then Anthropic, then Google Gemini. A provider with an empty key field or a failed check is skipped.

**API Key.** Holds your key for the provider whose section it sits in, with one field each under **Anthropic**, **OpenAI**, and **Google Gemini**. Each field starts empty. Fill in your default provider's, and a second only if you want a fallback. The key is stored in the Keychain, so it survives a restart.

**Model.** Chooses which of the company's models answers, with one picker per provider section. The default is the entry marked Recommended, which is Claude Sonnet 4.6 for Anthropic, GPT-5.5 for OpenAI, and Gemini 3.5 Flash for Google Gemini. Leave it at the default for a first run. If the picker shows your saved value as a Custom entry, LGE no longer lists that model, so pick a listed one.

**Use Azure AI-hosted endpoint.** Sends the OpenAI requests to a model your organization runs on Microsoft's Azure cloud instead of to OpenAI. The default is off. This and the next two entries matter only when an administrator gave you the values. Turn it on after you fill in the two fields below, and put the administrator's key in the **OpenAI** API Key field, which this route reads.

**Endpoint.** Holds the web address your Azure administrator gives you, shaped like the placeholder `https://example.openai.azure.com`. It starts empty and has no effect while the Azure toggle is off.

**Deployment.** Holds the deployment name your Azure administrator gives you, a label your organization chose that is not always the model's own name. It starts empty, with `gpt-5-mini` as placeholder text. Change it when your administrator gives you a new one.

<!-- SHOT: ai-assistant-azure-endpoint -->

**Clear All Keys.** Removes all three provider keys from the Keychain at once. Use it when you hand the Mac on or when a key has been exposed. LGE first asks "Clear All API Keys?" and warns that you will need to enter the keys again. There is no undo.

## Reading the results

A reply is one message in the Assistant tab. Its value depends on whether it was a [grounded answer](../../GLOSSARY.md#grounded-answer), meaning based on a real lookup in your data rather than on the model's recollection. Two signs tell you.

The first is the status line in the header, which shows "Searching genes...", "Reading variant table...", or "Listing chromosomes..." before a reply that came from your data.

The second is the reply itself. A grounded sentence names things you can check, such as the bundle name the **Data sent…** popover shows, a chromosome from your reference, and counts that match the number at the right end of the Variants tab's row, which reads like "N variants total" or ends "(N total)". A sentence that describes a gene in general terms, with nothing from your project, probably was not grounded, so ask again more specifically.

The assistant can run these lookups.

- Search genes and variants, and report the details of one named gene.
- Report variant statistics, and read the selected or visible rows of the Variants and Samples tables.
- Report what the viewport is showing, and list the names of the first 30 chromosomes or contigs, the separate named sequences of a [reference](../../GLOSSARY.md#contig-reference), with a count of any further ones.
- Search PubMed for papers. The search terms go to NCBI, which the **Data sent…** popover does not list.
- Move the view to a gene or to a region you name, the only change it can make anywhere in LGE.

It works in rounds, running lookups and reading the answers before it replies, and it stops after eight rounds. You do not see the rounds, and a single clear question usually takes one or two. Some replies come from LGE rather than the model. A reply that ends "No configured AI provider has a valid API key with available credits." means no key passed its check, which a dropped connection also causes. A reply beginning "AI provider quota exceeded" means the account is out of credits or over a limit, so add credits or fill in a second provider with its own account. A reply beginning "I reached the maximum analysis steps without a final text response" means the eight rounds ran out, and it is the only sign that they did, so split the question into parts. When the model returns nothing readable, the panel still ends with a message, such as "The AI request completed without a displayable response."

When a gene, variant, or region comes up, the assistant also suggests wet-lab follow-ups such as assays and reagents. This cannot be turned off, and it is safe to ignore. Treat every reagent it names as a lead to check against the vendor's datasheet, never as a validated choice.

## What good looks like

Four checks separate a reply you can act on from one to set aside.

1. The numbers match the count at the right end of the Variants tab's row, which is the correct count.
2. The answer names your data, meaning your bundle, your organism, and your coordinates.
3. You read **Data sent…** before sending anything sensitive.
4. Nothing changed. The assistant edits no files, runs no workflow, and imports or deletes no bundles. If a bundle looks different after a conversation, the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P), shows what changed it.

## On the command line

This section is optional, and you can skip it if you do not use a terminal. The AI Assistant has no command-line counterpart. `lungfish-cli genotype ai-haplotyping` does call a model, for genotyping work, with its own provider flags listed in [CLI Reference](cli-reference.md). It retries a dropped connection or a rate limit up to `--max-provider-retries` times, 2 by default, but a used-up quota stops the run at once with an error that ends "AI provider quota is exhausted. Check provider billing or use another configured provider."

## Next

Every other chapter of this manual works without an AI provider. Return to [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md) for how projects are organized.
