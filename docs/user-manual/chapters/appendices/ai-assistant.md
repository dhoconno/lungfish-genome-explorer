---
title: The AI Assistant Panel
chapter_id: appendices/ai-assistant
audience: bench-scientist
prereqs: [01-foundations/06-the-lungfish-project]
estimated_reading_min: 5
task: Open the AI Assistant panel, connect a bring-your-own-key provider, and ask questions about the active dataset.
tags: [ai-assistant, reference, byo-key, help]
tools: []
entry_points:
  - "View > AI Assistant"
shots: []
planned_shots:
  - id: ai-assistant-panel
    caption: "The AI Assistant panel docked beside a dataset viewport with a question about the active result and its answer."
  - id: ai-assistant-provider-setup
    caption: "The provider settings where a bring-your-own-key credential is entered for the AI Assistant."
illustrations: []
glossary_refs: [ai-assistant, provenance]
features_refs: [ai.assistant]
fixtures_refs: []
brand_reviewed: true
lead_approved: false
---

## What it is

The AI Assistant is a chat panel inside Lungfish that answers questions
about the dataset you have open. Instead of hunting through menus, you can
type a plain question like "what is in this bundle?" or "what does this
dialog mean?" and get an answer written against your current data. Behind the
scenes it reads the state of the active viewer (the loaded bundle, the
organism, the region you are viewing, and the rows selected in the variant or
sample tables), so its answers refer to what is actually in front of you.

This is a bring-your-own-key feature: the assistant does not include a model,
and Lungfish does not run one for you. You connect your own account with an
external AI provider by entering an API key, and requests go to that
provider under your key. Any supported provider works, and the panel stays
neutral about which one you pick. This panel is still changing release to
release, so what it answers well today may shift. The bottom line: treat it
as an assistant for interpreting and navigating your data, not as a source of
record.

<!-- planned: ai-assistant-panel -->

## What you will learn

This appendix shows you how to open the AI Assistant panel, connect a
bring-your-own-key provider, and ask a question about the active dataset,
and it maps where the line falls between what the assistant can do for you
and what it deliberately will not do.

## Connecting a bring-your-own-key provider

Before the assistant can answer anything, connect a provider. A
bring-your-own-key provider is an external AI service you hold your own
account and API key for. Lungfish supports three: Anthropic, OpenAI, and
Google Gemini. Open **Lungfish > Settings** and go to the **AI Services**
tab. Choose your preferred provider, paste your API key, and enable AI
services. Lungfish stores the key in the system keychain, not in your
project. You can configure more than one. The assistant uses your preferred
provider first, then falls back through the others in turn, so if your
primary is unreachable because of a network problem, a rate limit, or an
empty balance, a second configured provider can still answer. A provider
whose key is missing or out of credit is skipped rather than tried. If you
have not chosen a preference, Anthropic is the default.

If no key is set, the panel will tell you AI services are disabled and point
you back to this tab. Nothing you type is sent anywhere until a valid key is
in place.

<!-- planned: ai-assistant-provider-setup -->

## Procedure

### Step 1. Open the AI Assistant panel

Choose **View > AI Assistant**. The panel opens as a floating window beside
your main window and stays visible while you work. A short welcome message
greets you, along with a set of suggested questions drawn from whatever is
currently loaded, so you can click one to get started instead of typing.

### Step 2. Ask a question about the active dataset

Type a question into the field at the bottom and press Return. A thinking
indicator appears while your provider responds. The answer follows, and you
can copy it with the button on the reply. Good questions are
grounded in your data: "summarize this bundle", "what genes are in my
current view?", "explain what this taxonomy result is telling me", or "which
workflow should I use to call variants here?". Because the assistant sees
your selected and visible table rows, you can also ask it about "these
variants" or "the selected samples" and it will read the current selection
before answering.

### Step 3. Clear the conversation when you switch context

The **Clear** button at the top of the panel wipes the current conversation
and starts fresh. It removes every message, restores the welcome message,
and brings back the suggested questions drawn from your loaded data.
Clearing is local to the panel and changes nothing in your project. Use it
when you move to a different dataset, or when a long thread has drifted and
you want the assistant to reason from a clean slate.

## What the assistant can and cannot do

On the can-do side, the assistant interprets and explains, and it looks
things up in your loaded data. Within a single request it reads the active
viewer state, searches your genome data for genes and variants, reports
variant statistics and gene details, moves the browser view to a gene or
region you ask about, and searches PubMed for related literature. When you
ask about a specific gene, variant, or region, it also volunteers practical
wet-lab follow-ups on its own: candidate assays such as expression, protein,
or functional readouts, and species-appropriate reagents, prioritizing
antibodies validated in your dataset's organism and flagging when only
cross-reactive ones are likely. Treat those reagent suggestions as leads to
confirm against vendor datasheets and current literature, never as validated
picks. Where it helps most is explaining a result, a dialog, or an
unfamiliar term, and suggesting which workflow fits your question.

What it cannot do is change your data or your project. This is not a
data-modifying agent: it does not edit files, run analysis workflows or
classifiers, import or delete bundles, or make changes on your behalf beyond
moving the view. Its lookups are read-only. Because it changes nothing, its
answers are not written into your project's provenance record, which tracks
the tools and parameters that produced your data. Treat its output as
guidance to check, not as a result to cite. When a question needs data that
is not loaded, or the assistant is uncertain, a well-behaved answer will say
so.

## Next

Return to [The Lungfish Project](../01-foundations/06-the-lungfish-project.md)
for how projects and their provenance records are organized.
