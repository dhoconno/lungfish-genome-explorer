# StatusPill

A capsule that reports a setup or tool state with a colored dot and a short title-case label.

Hand-written from `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift` (`StatusPill`).

- Use it in a header row to report one state, such as "Core Tools Installed" (`sage`), "Setup Needed" (`creamsicle`) or "Checking Core Setup" (`warm-grey`).
- The fill is the dot color at 12% (`success-fill`, `attention-fill`, `muted-fill`, `danger-fill` on the web). The label is `app-pill` in `ink`.
- The consumer supplies the label and the state. Always pass a word. The dot alone never carries meaning.
- Do not use it as a button or put more than one per header.
