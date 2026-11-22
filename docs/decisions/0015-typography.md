# 0015. Typography: Publico Text, DM Sans, iA Writer Mono

**Decided.** Kuri's text uses three faces:

- **Publico Text** (serif: replies, headings, accents). An Apple-licensed font that macOS downloads on request; Kuri asks Core Text for it at launch and uses *Iowan Old Style*, which ships with macOS, until it arrives.
- **DM Sans** (sans: user messages and the interface). Bundled with the app.
- **iA Writer Mono** (code). Bundled with the app, set at 0.86 of the surrounding size.

**Why.** The redesign wants a warm, classy reading face, an interface sans with some character that still feels at home on a Mac, and a mono with a slightly organic feel ([ui.md](../ui.md)). The faces were picked by eye in the Autumn sketch, against the system fonts and several alternatives.

**Where fonts may come from.** The dependency rule (Apple first, then official sources) extends to fonts: a font either ships with macOS, is one Apple provides as an on-demand download, or is open-licensed (SIL Open Font License) and bundled from its official source, with its licence next to it. DM Sans and iA Writer Mono are OFL. Fonts whose licences forbid redistributing the files (Satoshi, for instance) can't be used: Kuri's repository is public.

**Cost.** Two bundled font families (a few hundred KB) and their licences; a first launch without network shows Iowan Old Style until Publico Text is downloaded.
