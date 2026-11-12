# Designs

Copied from the design canvas:
https://claude.ai/artifact/GqsEQ9WZbmCBrk5RGNcBKX

| #   | Board                                  | Spec                                             | Source                                                                                                                                                           |
| --- | -------------------------------------- | ------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Window with face tabs                  | [01-window-face-tabs.md](01-window-face-tabs.md) | [Main.dc.html](source/Main.dc.html)                                                                                                                              |
| 2   | Agent faces                            | [02-agent-faces.md](02-agent-faces.md)           | [States.dc.html](source/States.dc.html)                                                                                                                          |
| 3   | `+` button: new tab by account         | [03-new-tab-menu.md](03-new-tab-menu.md)         | [NewTab.dc.html](source/NewTab.dc.html)                                                                                                                          |
| 4   | Notifications and dock badge           | [04-notifications.md](04-notifications.md)       | [Notify.dc.html](source/Notify.dc.html)                                                                                                                          |
| 5   | Agents panel                           | [05-agents-panel.md](05-agents-panel.md)         | [Agents.dc.html](source/Agents.dc.html)                                                                                                                          |
| 6   | Face sets (Orbs, Shapes, Bots, Spark)  | [06-face-sets.md](06-face-sets.md)               | [FacesOrbs](source/FacesOrbs.dc.html), [FacesShapes](source/FacesShapes.dc.html), [FacesBots](source/FacesBots.dc.html), [FacesSpark](source/FacesSpark.dc.html) |
| 7   | Grid View: all tabs at once            | [07-grid-view.md](07-grid-view.md)               | —                                                                                                                                                                |
| 8   | Code Review: check the agent's changes | [08-code-review.md](08-code-review.md)           | —                                                                                                                                                                |

## Viewing them

- **`canvas-export.html`** is a standalone export of the whole canvas. Open it
  in a browser; it works offline.
- **`source/*.dc.html`** are the boards' source files. They need the canvas
  runtime to render, so they're here for reference (exact colors, sizes,
  animations), not for opening directly.
- The **`.md` specs** are what to build against.

## Shared tokens

| Token             | Value     | Used for                     |
| ----------------- | --------- | ---------------------------- |
| Idle              | `#8b9099` | Idle face                    |
| Working           | `#5ca0ff` | Working face, spinner        |
| Waiting           | `#f5a524` | Waiting face, pulse, "?"     |
| Done              | `#3fb950` | Done face                    |
| Error             | `#f85149` | Error face                   |
| Face features     | `#15161b` | Eyes and mouths              |
| Bar background    | `#22242a` | Tab bar                      |
| Selected tab      | `#363944` | Selected tab highlight       |
| Hovered tab       | `#2c2e35` | Hovered tab highlight        |
| Card background   | `#24262d` | Hover card, border `#3a3d47` |
| Account: Work     | `#8b7cf6` | Example account color        |
| Account: Personal | `#2dd4bf` | Example account color        |

Fonts: Inter for UI, JetBrains Mono for terminal text.
