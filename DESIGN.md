# Design principles

Knob is a switch you glance at, flip, and forget. Every change has to pass these rules.

## UX

- **Zero cognitive load.** One panel, no settings window, no menus inside menus. If a control needs explaining, it is the wrong control.
- **State in words and color.** Every switch says what it is doing right now ("Live", "Muted", "Silent", "In use", "Not connected"). Color only reinforces the words, so it still reads for color blind users and at a glance.
- **Instant effect.** Clicking does the thing. There is no Save, Apply, or confirm step, and every action is undone by doing it again.
- **Feedback for every action.** The tile changes color and the F5 key shows a large HUD on the laptop screen, so you never wonder whether it worked.
- **The truth comes from the system.** Mute state is read from the device each time, never from a cached flag, so the panel can't disagree with reality.
- **Big targets.** Tiles are about 155×108 pt, rows and pill buttons are 40 pt tall, and icon buttons are 30 pt circles. Everything you can click shows a hand cursor and lights up under the pointer.
- **Quiet by default.** Section titles are one word. Explanations such as "drag to reorder" live in tooltips, not on screen.
- **Safe defaults.** First launch changes nothing. New devices rank last, except the device already in use. Quitting or killing Knob gives F5 back to dictation.

## Visual

- Native AppKit, system materials, and SF Symbols, so it looks right in light and dark mode and on every macOS version.
- The panel is a Liquid Glass card (`NSGlassEffectView`) floating just under the notch. It opens on hover with no delay, closes 0.3 s after the pointer leaves, and never takes keyboard focus.
- The device in use gets a checkmark and a soft pill. Claude orange only for the Claude voice tile, red only for "muted". Everything else is neutral and sits straight on the glass.
- Choices are big pills; the selected one turns solid white. The display size is a thick Control Center style slider with a round white handle that snaps to stops. Rare actions such as Quit stay small text.
- Control Center layout: big square tiles for on and off switches, then lists, then rarely changed options in one row each, then Quit.

## Resources

- Event driven only: CoreAudio property listeners, one Carbon hotkey, and a tracking area over the notch. The only timer is the 2 minute port rescan, and it runs only while the panel is open.
- Nothing is drawn or rebuilt while the panel is closed.
- Disk writes happen only when the device order really changes.
- The target is 0% CPU and zero wakeups while idle, and under about 35 MB of memory even after the panel has been opened.
