# RecentProjectCard

A single-line row that reopens a recent project, showing its name, its path and when it was last opened.

Hand-written from `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift` (`RecentProjectCard`).

- Stack rows with `space-8` between them. Minimum height 64px, padding `space-12` by `space-18`, radius `radius-20`, fill `card`, 1px `stroke` border.
- The icon well is 40px at `radius-14` with a `creamsicle` folder glyph.
- Name is `app-project-name`, one line. The path is 12px `text-secondary`, truncated in the middle. The date is `app-caption` at the trailing edge.
- On hover the border turns `creamsicle` at 28%. Never wrap to a second line.
