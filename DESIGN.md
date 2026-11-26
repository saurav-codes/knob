# Design principles

Knob is a switch you glance at, flip, and forget. Every change has to pass these rules.

## UX

- **Zero cognitive load.** One panel, no settings window, no menus inside menus. If a control needs explaining, it is the wrong control.
- **State in words and color.** Every switch says what it is doing right now ("On", "Muted", "Silent", "Default", "Open in Zoom", "Not connected"). Color only reinforces the words, so it still reads for color blind users and at a glance.
- **Instant effect.** Clicking does the thing. There is no Save, Apply, or confirm step, and every action is undone by doing it again.
- **Feedback for every action.** The tile changes color and the F5 key shows a large HUD on the laptop screen, so you never wonder whether it worked.
- **The truth comes from the system.** Mute state is read from every mic each time, never from a cached flag, and Knob listens for changes made elsewhere, so the panel can't disagree with reality. "Muted" means every mic. "Default" means the system default, and "Open in" means an app is recording.
- **Big targets.** Tiles are about 170×88 pt, rows are 34 pt tall, the two halves of a choice are 32 pt tall, and icon buttons are 28 pt circles. Everything you can click shows a hand cursor and lights up under the pointer, and buttons dip while pressed.
- **Quiet by default.** Section titles are a word or two. Explanations such as "drag to reorder" live in tooltips, not on screen.
- **Safe defaults.** First launch changes nothing. New devices rank last, except the device already in use. Quitting or killing Knob gives F5 back to dictation and unmutes the mics it muted.

## Visual

- Native AppKit and SF Symbols. The island is black with white ink whatever the system look, as the Dynamic Island is, with a key line so it keeps an edge over dark content and a soft shadow over light content.
- The panel is a black island that grows out of the notch. It opens on hover with no delay and closes 0.3 s after the pointer leaves. A screen without a notch gets a small black tab at its top centre that opens the same island.
- Motion follows the Dynamic Island: the outline springs from the notch to full size with a small overshoot (damping 0.78, response 0.26 s), and what is on it grows out and fades in a beat behind, so the moving edge never cuts through words. Closing runs back into the notch with no overshoot (damping 1, response 0.2 s). Every move starts from what is on screen, so it can be interrupted at any moment. With Reduce Motion on, the island only fades.
- Nothing is drawn to the island's edge. Each group sits in an inset card, and corner radii nest: 34 pt for the island, 18 pt for cards and tiles, 14 pt for rows inside a card.
- The default device gets a checkmark and a soft pill. Claude orange only for the Claude voice tile, red only for "muted". Everything else is white ink at three strengths: full for what matters now, 70% for labels and states, 52% for what is out of use.
- A two-way choice is one track with the chosen half raised, like a system segmented control, so it reads as a setting and not as a button that does something now. The display size is a thick Control Center style slider with a round white handle that snaps to stops. Rare actions such as Quit stay small text.
- Control Center layout: big tiles for on and off switches, then lists, then rarely changed options in one row each, then Quit. The tiles are the brightest blocks, so the eye lands on them first.

## Resources

- Event driven only: CoreAudio property listeners on the system and on each mic, one Carbon hotkey, and a tracking area over the notch or tab of each screen. The only timer is the 2 minute port rescan, and it runs only while the panel is open.
- Nothing is drawn or rebuilt while the panel is closed.
- Disk writes happen only when the device order really changes.
- The target is 0% CPU and zero wakeups while idle, and under about 35 MB of memory even after the panel has been opened.
