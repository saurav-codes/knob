# Knob

A tiny macOS menu bar utility for the few audio switches you touch every day. One click opens a panel with big, obvious controls.

- **Claude voice switch.** One big button turns Claude Code's spoken replies on or off. The knob in the menu bar is bright while Claude speaks and dull while it is silent.
- **Speaker and mic priority.** Drag your devices into the order you want. Knob always switches to the highest ranked device that is connected, so plugging in a new device never steals your audio. Speakers and microphone have separate lists, so you can keep AirPods for sound and the MacBook mic for calls.

## Lightweight by design

Knob does nothing until CoreAudio reports a device change or you click it. No timers, no polling, no background threads.

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

## License

MIT
