# 0023. A pixel meadow on the new chat page

**Decided.** The new chat page has a strip of pixel art along its bottom edge: a round chestnut tree on the right, short autumn grass running to the left edge, and wind that rolls across it in gusts, bending the grass, tipping the crown and carrying leaves at three depths (far ones slower and dimmer behind the tree, near ones faster and brighter in front). Now and then a burr drops, rolls clear of the trunk and splits to show the chestnut. A click on the tree shakes it: a damped sway, more leaves, sometimes a burr. The crown is grown from a seed, so each window gets a different tree of about the same size. It shows only on the new chat page and fades out with it. `meadow: false` in `config.json` (or Settings › General) turns it off; it's on by default.

- **Drawn as a bitmap, not as views.** The simulation fills a grid of 4-point pixels; each frame becomes a `CGImage` the size of the grid, set as the contents of a layer that Core Animation scales up with nearest-neighbour filtering. No SwiftUI update per frame.
- **Cheap at rest, still when unseen.** 12 frames a second (30 only while the tree sways after a click), and none while the window is hidden or Reduce Motion is on. Only the tree takes clicks; the rest of the strip lets them through.
- **Procedural, no assets.** Grass, earth, crown flecks and gaps come from a hash of grid positions; the crown is overlapping clusters, each in one autumn hue lit from the top left, scaled to a fixed box.

**Why.** The app's principles ask for essential, familiar software; a small living scene on an empty page gives it a character of its own (the chestnut is Kuri's emblem) without adding a feature to learn. Pixels read as old, reliable software while the rest of the window stays modern. Drawing a SwiftUI `Canvas` of rectangles cost about 10% CPU at 12 fps; the bitmap in a layer costs about 2%, measured in the sketch (`Sketches/Meadow.swift`), and about 0.3 MB of memory in the app.

**Cost.** A little CPU while a new chat page is on screen, and a file of simulation code to keep. It's decoration: anyone who'd rather not have it turns it off.
