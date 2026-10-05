# LaunchActionTile

A large rounded card that starts a top-level action from the Welcome window, with an icon well, a title and a one-line description.

Hand-written from `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift` (`LaunchActionTile`).

- Lay tiles out in a row with `space-18` gutters. Minimum height 176px, padding `space-22`, radius `radius-24`, fill `card`, 1px `stroke` border.
- The icon well is 54px, `radius-18`, `icon-well` fill, with a 24px `creamsicle` glyph.
- Title `app-tile-title` in `ink`, description 15px in `text-secondary`, three lines at most.
- On hover the border turns `creamsicle` at 35%. Disabled tiles drop to `opacity-disabled`.
- The consumer supplies the glyph, title, description and action. Keep to two or three tiles per row.
