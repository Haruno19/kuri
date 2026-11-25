# 0024. Mac conventions under the custom look

**Decided.** Kuri keeps its own look (bundled faces, pencil icons, a warm palette, no toolbar: [ui.md](../ui.md)), but under it behaves the way the Human Interface Guidelines expect of a Mac app:

- **Every action is in the menu bar.** File › New Chat (⌘N); a Chat menu with Stop (⌘.), Retry (⌘R), Continue, Attach Folder… (⇧⌘O), Compact Chat, Rename Chat and Delete Chat…; View › Show Sidebar and Show Inspector. Buttons and context menus are shortcuts to these, never the only way.
- **Deleting a chat asks first.** It can't be undone, so the confirmation names the chat and its button says Delete Chat. The Delete key in the sidebar asks the same.
- **Text reads at 4.5:1.** Three greys: `secondary`, `dim` for the quietest text that still informs (times, counts, status, hints) and `faint` only for icons and rules beside text. Error text uses `accentText`; filled controls with a white label use a deeper chestnut. With Increase Contrast each grey steps up one.
- **Reduce Motion fades.** Animations from `Tune` turn into short fades, transitions that move or scale go through `AnyTransition.moving`, and things that move all the time (the working dots, the shimmer, the sidebar orb, the meadow) hold still. The logo only shines when clicked.
- **Icon-only controls have names.** Pencil icons are hidden from VoiceOver; every button made of one carries an accessibility label, and status drawn as a dot or a colour is also said in words. Controls that only appear on hover are in a context menu too, and small crosses get a 20-point target.
- **The menu bar icon can be turned off** (`menuBarIcon`). Without it Kuri keeps its Dock icon and ignores `startInBackground`, so there's always a way back to a window.
- **Errors say what failed.** The alert's title names the action ("Couldn't send the message"); settings that fail say so under their control.
- **Words.** One term for one thing: *chat*, never *conversation*, in the interface. Menu items and buttons in title case.

**Why.** The custom look is a choice; breaking what people expect from every Mac app (menus, VoiceOver, Reduce Motion, contrast) isn't part of it. These cost nothing visible to someone who doesn't need them.

**Cost.** Menu commands act on the main window's chat, not the mini window's. The dim grey is darker than the old faint text, so the quietest text stands out a little more.
