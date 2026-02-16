# Settings

## Accessing Settings

Open Settings from the menu bar: **Lungfish > Settings** (Cmd+,)

Settings are organized into sections that can be individually reset to defaults.

## AI Services

Configure the AI Assistant's language model providers.

### AI Search Enabled

Master toggle for all AI features. When disabled, the AI Assistant will not send requests to any provider.

### Preferred Provider

Choose which AI provider to use first:
- **Anthropic** (default) — Uses Claude models
- **OpenAI** — Uses GPT models
- **Google Gemini** — Uses Gemini models

If the preferred provider fails, the assistant automatically tries the next configured provider.

### API Keys

Each provider requires its own API key. Keys are stored securely in the macOS Keychain:

- **Anthropic API Key**: Get from console.anthropic.com
- **OpenAI API Key**: Get from platform.openai.com/api-keys
- **Gemini API Key**: Get from aistudio.google.com/apikey

### Model Selection

Choose which model to use for each provider:

- **Anthropic**: claude-sonnet-4-5-20250929 (default)
- **OpenAI**: gpt-5-mini (default)
- **Gemini**: gemini-2.5-flash (default)

### Reset AI Services

Click **Reset** to restore all AI settings to defaults. This clears model selections and preferred provider but does not delete stored API keys from the Keychain.

## General Settings

### Appearance

Lungfish follows your macOS system appearance (Light or Dark mode) automatically.

### File Handling

The app registers file associations for common genomic formats:
- `.lungfish` / `.lungfishbundle` — Genome bundles
- `.fa` / `.fasta` — FASTA sequence files
- `.gff` / `.gff3` — GFF annotation files
- `.vcf` — Variant Call Format files
- `.gb` / `.gbk` — GenBank flat files

Double-clicking these files in Finder will open them in Lungfish.

## Resetting Settings

Each settings section has a **Reset** button to restore that section's defaults without affecting other sections. To reset all settings, use each section's Reset button individually.
