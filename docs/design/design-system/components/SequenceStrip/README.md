# SequenceStrip

A run of nucleotide cells colored by base, as the read and sequence viewers draw them.

Hand-written from `Sources/LungfishApp/Views/Viewer/OperationPreviewView.swift` and the defaults in `Sources/LungfishApp/Views/Settings/AppearanceSettingsTab.swift`.

- Fills come from `base-a`, `base-c`, `base-g`, `base-t` and `base-n`. U uses the `base-t` color.
- Letters are `code` family at 19px bold or larger. A and G letters are `deep-ink`, the rest white, so each pair holds at least 3:1.
- The consumer supplies the sequence. Base colors are user preferences, so read them from settings rather than hard-coding.
- Never reuse base colors for status or charts.
