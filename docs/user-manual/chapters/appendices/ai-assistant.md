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
dialog mean?" and get an answer written against your current data. The panel
reads the state of the active viewer (the loaded bundle, the organism, the
region you are viewing, and the rows selected in the variant or sample
tables) so its answers refer to what is actually in front of you.

The assistant is a bring-your-own-key feature: it does not include a model,
and Lungfish does not run one for you. You connect your own account with an
external AI provider by entering an API key, and requests go to that
provider under your key. The panel is provider-neutral and works with any of
the supported providers. This panel is still changing release to release, so
what it answers well today may shift. The bottom line: treat it as an
assistant for interpreting and navigating your data, not as a source of
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
account and API key for. Open **Lungfish > Settings** and go to the **AI
Services** tab. Choose a provider, paste your API key, and enable AI
services. Lungfish stores the key in the system keychain, not in your
project. You can configure more than one provider: if your primary provider
is unreachable because of a network problem or a rate limit, the assistant
tries the next one you configured.

If no key is set, the panel will tell you AI services are disabled and point
you back to this tab. Nothing you type is sent anywhere until a valid key is
in place.

<!-- planned: ai-assistant-provider-setup -->

## Procedure

### Step 1. Open the AI Assistant panel

Choose **View > AI Assistant**. The panel opens as a floating window beside
your main window and stays visible while you work. It opens with a short
welcome message and a set of suggested questions drawn from whatever is
currently loaded, so you can click one to get started instead of typing.

### Step 2. Ask a question about the active dataset

Type a question into the field at the bottom and press Return. The panel
shows a thinking indicator while your provider responds, then displays the
answer, which you can copy with the button on the reply. Good questions are
grounded in your data: "summarize this bundle", "what genes are in my
current view?", "explain what this taxonomy result is telling me", or "which
workflow should I use to call variants here?". Because the assistant sees
your selected and visible table rows, you can also ask it about "these
variants" or "the selected samples" and it will read the current selection
before answering.

## What the assistant can and cannot do

The assistant can interpret and explain, and it can look things up in your
loaded data. It reads the active viewer state, searches your genome data for
genes and variants, reports variant statistics and gene details, moves the
browser view to a gene or region you ask about, and searches PubMed for
related literature. It is well suited to explaining a result, a dialog, or
an unfamiliar term, and to suggesting which workflow fits your question.

The assistant cannot change your data or your project. It is not a
data-modifying agent: it does not edit files, run analysis workflows or
classifiers, import or delete bundles, or make changes on your behalf beyond
moving the view. Its lookups are read-only, and because it changes nothing,
its answers are not written into your project's provenance record, which
tracks the tools and parameters that produced your data. Treat its output as
guidance to check, not as a result to cite. When a question needs data that
is not loaded, or when it is uncertain, a well-behaved answer will say so.

## Next

Return to [The Lungfish Project](../01-foundations/06-the-lungfish-project.md)
for how projects and their provenance records are organized.
