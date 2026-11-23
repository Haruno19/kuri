# UI and UX

The brief for the redesign. Every app change is checked against it. Directions are tried as sketches in `Sketches/` (small standalone apps) before they touch `App/`.

## Principles

1. **Essential.** The main window is for the conversation. Anything about configuration goes to Settings. Every control earns its place: the user can reach everything they *need*, nothing more. No decoration that doesn't help the interaction.
2. **Interaction first.** Motion and feedback are the heart of the design and get the most care. The app should feel friendly, warm and responsive.
   - Everything that enters or leaves the view moves: natural and smooth, never exaggerated. Prefer springs and short durations (≈0.25–0.45 s). Things grow from where they come from and shrink to where they go.
   - Every interaction answers: hover, press, click and drop give immediate, physical feedback.
   - Expect to iterate on timings with the author; keep them as named constants, easy to tune.
3. **Space serves use.** In the chat, the text gets the room: wide reading column, little chrome. Settings and configuration go the other way: a compact, information-dense, slightly retro layout (tight rows, small type, grouped boxes) instead of airy spacing.

## Style

- **Classy and warm**, built from **layers and depth**: surfaces sit on surfaces, with real shadows and light from above.
- **Light and dark** themes, following the system unless `appearance` in `config.json` picks one ([config.md](config.md)).
- **Autumn palette**: chestnut, amber, toasted cream, warm brown-blacks. The accent is the app icon's chestnut gradient (top `p3(0.60, 0.35, 0.16)` → bottom `sRGB(0.73, 0.58, 0.34)`; the dark icon starts at `p3(0.50, 0.31, 0.14)`). No cold greys: neutrals are warm.
- **Type** (see decisions [0015](decisions/0015-typography.md) and [0018](decisions/0018-literata.md) for where each font comes from):
  - **Serif** (model replies, headings, accents): *Literata*, bundled ([decision 0018](decisions/0018-literata.md)).
  - **Sans** (user messages and the rest of the UI: titles, model selector, buttons): *DM Sans*, bundled.
  - **Mono** (code): *iA Writer Mono*, bundled, set smaller than the text around it (×0.86).
- **Code blocks**: syntax colours from the author's Everforest themes ([everforest-vscode](https://github.com/Haruno19/everforest-vscode)): *Higure* in dark mode, *Yoake* (its light counterpart) in light mode.
- **Glass**: Liquid Glass (`glassEffect`) and materials where something floats above the content (composer, floating buttons, popovers), so the app feels first-party and modern.
- **Icons**: look hand-drawn with a pencil: slightly irregular strokes, round caps, a graphite feel. Custom shapes, not SF Symbols, wherever the user sees them in the main window.

## Main window layout

- **No toolbar.** Native traffic lights stay. The sidebar toggle floats in the top-left corner, next to them. Everything else (model selector, folders, attachments, send/stop) lives in the composer.
- **Sidebar starts collapsed**: the app opens on the chat alone. At its top, *New chat* is the primary button (filled in the accent, like send) and *Settings* a secondary one (outlined) below it.
- **New chat**: content centred vertically; Kuri's logo and a welcome line side by side on one row, aligned left, above the composer.
- **Logo**: made of the glassy material, coloured with the icon's chestnut gradient. Always alive in a subtle way: idle motion, reacting to hover and clicks (a tilt toward the pointer, a squish and bounce on click). Not anthropomorphic, but with the same friendly, human feel.
- **Reasoning while it streams**: a window of its latest lines, at most ten or about 30% of the room between the pinned message and the composer, older lines fading out at the top. Finished reasoning folds into *Thought*.
- **Working state**: while the model thinks or runs tools, an animated indicator (the logo, or dots moving in 3D) next to shimmering text saying what's happening.
- **User messages**: full width, aligned left, in rich, heavy, 3D-feeling cards (layered fill, top highlight, darker lower edge, contact and ambient shadows).
- **Model replies**: serif, directly on the surface, no bubble.
- **Composer**: glass, slightly tinted, with a shadow so it sits above the surface. The transcript frosts and fades where it meets the window's top edge and again behind the composer, rising a little above it. The model selector and the other controls blend into the composer surface (no boxes of their own); only send/stop is a distinct button.

## UI roadmap

1. Full Markdown, including LaTeX (deferred earlier), with code blocks highlighted in the Everforest colours. *(done)*
2. Layout and styling of the main window, from the Autumn sketch, with conversation management: rename *(done)*, archive, delete; maybe projects / groups, or grouping by root folder.
   - **Running chats** show a status indicator in the sidebar: a single orb in the accent colour, with the same 3D feel as the working dots.
   - **Sidebar snaps shut**: dragging its edge past a threshold collapses it, if SwiftUI allows it.
3. **Menu bar icon and mini window** *(done)*: left click opens a small chat in Liquid Glass that floats like picture in picture; right click a native menu (Open Kuri, Settings, Quit). This also covers the floating window, item 5.
4. Settings window (compact, retro, dense).
5. Floating window: the mini window above; a global hotkey for it is still to do.
6. **Right sidebar**: an inspector for the conversation, in sections (sketched in `Sketches/Inspector.swift`, stacked or as tabs):
   - **Steps**: every tool call of the conversation, with the shell commands in the foreground.
   - **Tasks**: the model's task list, when it made one, editable by the user.
   - **Context**: what fills the context window.
   - **Git**: when the working folder is a repository, its branch and changes.
   - **Sandbox preview**: shown while the model uses the sandbox, previewing what happens in it.
7. **Playing with the window** (after Markdown, Settings and the menu bar): give it a polished, slightly retro taste. Ideas to try: a background pattern (a faint grid) instead of the solid colour, a resized logo, small pixel animations on the composer's top-right edge.
