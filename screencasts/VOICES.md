# Narration voices (decision pending, 2026-10-02)

The learner videos (B00 to B04) were drafted with the macOS voice Ava (Premium) through `say`. Two problems make that a draft-only voice.

- It sounds synthetic.
- Apple's macOS licence allows system voices for personal, non-commercial use only, and names recording or publishing them in a public, non-profit or commercial context as not permitted (checked in the Sonoma and Sequoia licences, and assumed unchanged in Tahoe). Public videos therefore need a licensed voice.

`render.py` now supports three engines through the spec's `narration.engine` key. `say` stays for drafts.

## Recommendation

| | Engine | Model | Voices to audition | Key |
|---|---|---|---|---|
| Primary | ElevenLabs | `eleven_v4` (pin `eleven_v3` if v4 misbehaves) | Talia, Elara, Darian (permanent stock voices, the old defaults expire 2026-12-31) | `ELEVENLABS_API_KEY` |
| Fallback | OpenAI | `gpt-4o-mini-tts` | `marin`, `cedar` | `OPENAI_API_KEY` |

ElevenLabs was judged the most natural for calm instructional narration and supports phoneme rules for scientific terms. A paid plan is needed for commercial use without attribution (Starter covers this volume, `wav_24000` output). OpenAI is simpler and cheaper, steers style through `instructions`, but has no phoneme control. Its policy requires telling viewers the voice is AI-generated, which the Videos page and transcripts already do. Cost is negligible at this scale (under a dollar per full re-render of all videos).

## Morning steps

1. Add the key to `~/.env` (for example `ELEVENLABS_API_KEY=...`). `render.py` reads it from the environment or `~/.env` and never prints it.
2. In the ElevenLabs voice library, copy the voice ID of the chosen voice.
3. Change each learner spec's `narration` block, for example:

```yaml
narration:
  engine: elevenlabs
  model: eleven_v4
  voice_id: <copied voice id>
  seed: 4242
  voice_settings: {stability: 0.6, similarity_boost: 0.75, style: 0, speed: 0.95}
  lead: 0.5
  tail: 0.6
  lexicon: { ... unchanged ... }
```

   or for OpenAI:

```yaml
narration:
  engine: openai
  model: gpt-4o-mini-tts
  voice: marin
  instructions: Calm, warm, unhurried university instructor explaining a lab procedure.
  lead: 0.5
  tail: 0.6
  lexicon: { ... unchanged ... }
```

4. Render one video, listen, then render the rest. Each narration line is cached by its text and every voice setting, so a later remake only re-synthesizes lines that changed.

## Pronunciation

Each spec's `lexicon` rewrites terms before they reach any engine (HG002 to "H G zero zero two", minimap2 to "mini map two", FASTQ to "fast Q", Q30 to "Q thirty", kb to "kilobase"), so it works with every provider. Use an ElevenLabs pronunciation dictionary with IPA only where respelling fails (for example "heterozygous"), and pin its version ID.

## Already published

B01 is on the public Videos page with the Ava narration. Re-render and replace it once the new voice is chosen, or take it down first if the licence concern should be resolved immediately.
