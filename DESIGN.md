# Design principles

Knob is a switch you glance at, flip, and forget. Every change has to pass these rules.

## UX

- **Zero cognitive load.** One panel, no settings window, no menus inside menus. If a control needs explaining, it is the wrong control.
- **State in words and color.** Every switch says what it is doing right now ("Live", "Muted", "Silent", "In use", "Not connected"). Color only reinforces the words, so it still reads for color blind users and at a glance.
- **Instant effect.** Clicking does the thing. There is no Save, Apply, or confirm step, and every action is undone by doing it again.
- **Feedback for every action.** The tile changes color and the F5 key shows a large HUD on the laptop screen, so you never wonder whether it worked.
- **The truth comes from the system.** Mute state is read from the device each time, never from a cached flag, so the panel can't disagree with reality.
- **Big targets.** Tiles are about 145×104 pt and rows are 38 pt tall. Everything you can click shows a hand cursor.
- **Obvious affordances.** Rows that can be dragged show a grip (≡) and their rank number. A one-line hint sits next to each section title.
- **Safe defaults.** First launch changes nothing. New devices rank last, except the device already in use. Quitting or killing Knob gives F5 back to dictation.

## Visual

- Native AppKit, system materials, and SF Symbols, so it looks right in light and dark mode and on every macOS version.
- One accent color (dark forest green) for "this is in use", Claude orange only for the Claude voice tile, red only for "muted". Everything else is neutral grey.
- On a notched screen the panel is black and drops straight out of the notch, so it reads as the notch growing. It opens on hover with no delay, closes 0.3 s after the pointer leaves, and never takes keyboard focus.
- Control Center layout: big square tiles for on and off switches, then lists, then rarely changed options, then Quit.

## Resources

- Event driven only: CoreAudio property listeners, one Carbon hotkey, and a tracking area over the notch. The only timer is the 2 minute port rescan, and it runs only while the panel is open.
- Nothing is drawn or rebuilt while the panel is closed.
- Disk writes happen only when the device order really changes.
- The target is 0% CPU and zero wakeups while idle, and under about 35 MB of memory even after the panel has been opened.
