# Knob

A tiny macOS notch utility for the few audio switches you touch every day. Hover the notch and a panel with big, obvious controls drops out of it.

- **Claude voice switch.** One big button turns Claude Code's spoken replies on or off.
- **Speaker and mic priority.** Drag your devices into the order you want. Knob always switches to the highest ranked device that is connected, so plugging in a new device never steals your audio. Speakers and microphone have separate lists, so you can keep AirPods for sound and the MacBook mic for calls. Click ⊖ on a device, such as earphones with a poor mic, and Knob never switches to it again, even when macOS does on connect. ⊕ brings it back.
- **Open ports.** A collapsed section whose title counts what is running. Expand it to see every TCP port your own processes listen on, such as dev servers an agent started and forgot, with the folder it was started in and how long it has run. Click a row to open it in your browser, or ⏹ to stop the process. macOS services like AirPlay are hidden.
- **Lives in the notch.** No menu bar icon. Hover the notch to open the panel, and move the pointer away or click elsewhere to close it. Needs a Mac with a notch, and is out of reach while the lid is closed.
- **Mic mute tile and F5 key.** Click the Microphone tile, or press F5 (the dictation key on Mac laptops), to mute or unmute whichever mic is in use. A large icon on the laptop screen confirms the change. A switch in the panel gives F5 back to macOS dictation.

## Lightweight by design

Knob does nothing until CoreAudio reports a device change or you click it. Ports are scanned with `lsof` when the panel opens and every 2 minutes while it stays open, never while it is closed.

Measured on an M2 MacBook Air: 0% CPU and zero wakeups while idle, about 13 MB of memory, and no disk writes except when your device order changes.

## Install

Needs macOS 13 or later and the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/saurav-codes/knob.git
cd knob
./install.sh
```

This builds `~/Applications/Knob.app` and starts it at login. Run `./install.sh` again after pulling changes.

To remove it:

```sh
launchctl bootout gui/$(id -u)/io.github.saurav-codes.knob
rm -rf ~/Applications/Knob.app ~/Library/LaunchAgents/io.github.saurav-codes.knob.plist
```

## How the Claude switch works

Knob creates `~/.claude/voice-reply` when the voice is on and deletes it when it is off. Your Claude Code voice hook should exit early when that file is missing, for example:

```sh
[ -f "$HOME/.claude/voice-reply" ] || exit 0
```

Turning the voice off also stops any reply that is already playing.

## How the F5 key works

In "Mute mic" mode, Knob uses `hidutil` to remap the dictation key to F20 and catches F20 with a global hotkey, so it needs no Accessibility or Input Monitoring permission. Switching to "Dictation", quitting Knob, or removing it clears the remap. The remap applies to all keyboards until then.

See [DESIGN.md](DESIGN.md) for the design rules the app follows.

## License

MIT
