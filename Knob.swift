// Knob: a tiny menu bar utility. A switch for Claude's spoken replies, plus speaker and mic priority lists.
// The voice hook speaks only while ~/.claude/voice-reply exists.
// Audio work runs only when CoreAudio reports a device change; nothing polls.
import AppKit
import CoreAudio

let flag = NSHomeDirectory() + "/.claude/voice-reply"
let claudeOrange = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
let system = AudioObjectID(kAudioObjectSystemObject)

// The Claude spark: uneven rays around a center, drawn in code so the app ships no image files.
func spark(size: CGFloat, color: NSColor) -> NSImage {
  NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let lengths: [CGFloat] = [1, 0.78, 0.95, 0.82, 1, 0.74, 0.92, 0.86, 0.98, 0.76, 0.9, 0.8]
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let path = NSBezierPath()
    path.lineWidth = size * 0.1
    path.lineCapStyle = .round
    for (i, len) in lengths.enumerated() {
      let a = CGFloat(i) * .pi / 6 + (i % 2 == 0 ? 0.06 : -0.05)
      let r = (size / 2 - path.lineWidth / 2) * len
      path.move(to: c)
      path.line(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
    }
    color.setStroke()
    path.stroke()
    return true
  }
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
  var addr = address(selector)
  var value: Unmanaged<CFString>?
  var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
  return value?.takeRetainedValue() as String?
}

// Speakers or microphones: which default it controls, which streams a device needs, where its order is saved.
struct Kind {
  let title: String
  let defaultSelector: AudioObjectPropertySelector
  let scope: AudioObjectPropertyScope
  let key: String

  var defaultDevice: AudioDeviceID {
    get {
      var addr = address(defaultSelector)
      var id = AudioDeviceID(0)
      var size = UInt32(MemoryLayout<AudioDeviceID>.size)
      AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id)
      return id
    }
    nonmutating set {
      var addr = address(defaultSelector)
      var id = newValue
      AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    }
  }

  // Connected, visible devices of this kind, keyed by UID (stable across reconnects, unlike the ID).
  func connected() -> [String: AudioDeviceID] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size = UInt32(0)
    AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids)
    var result: [String: AudioDeviceID] = [:]
    for id in ids {
      var streams = address(kAudioDevicePropertyStreams, scope)
      var streamsSize = UInt32(0)
      AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamsSize)
      var hiddenAddr = address(kAudioDevicePropertyIsHidden)
      var hidden = UInt32(0)
      var hiddenSize = UInt32(MemoryLayout<UInt32>.size)
      AudioObjectGetPropertyData(id, &hiddenAddr, 0, nil, &hiddenSize, &hidden)
      if streamsSize > 0, hidden == 0, let uid = string(id, kAudioDevicePropertyDeviceUID) { result[uid] = id }
    }
    return result
  }

  var order: [String] {
    get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
  }
}

let kinds = [
  Kind(title: "Speakers", defaultSelector: kAudioHardwarePropertyDefaultOutputDevice,
       scope: kAudioObjectPropertyScopeOutput, key: "output"),
  Kind(title: "Microphone", defaultSelector: kAudioHardwarePropertyDefaultInputDevice,
       scope: kAudioObjectPropertyScopeInput, key: "input"),
]

// Menu bar mark: a knob inside its scale, bright while Claude speaks and dull when silent.
func menuIcon(bright: Bool) -> NSImage {
  let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let color = NSColor.black.withAlphaComponent(bright ? 1 : 0.4)
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)).fill()
    // Pointer cut out of the knob, turned toward the high end of the scale.
    let pointer = NSBezierPath()
    pointer.lineWidth = 1.8
    pointer.lineCapStyle = .round
    pointer.move(to: c)
    pointer.line(to: CGPoint(x: c.x + 3.2 * cos(.pi / 4), y: c.y + 3.2 * sin(.pi / 4)))
    NSGraphicsContext.current?.compositingOperation = .clear
    pointer.stroke()
    NSGraphicsContext.current?.compositingOperation = .sourceOver
    // Scale arc around the knob, open at the bottom like a volume dial.
    let scale = NSBezierPath()
    scale.lineWidth = 1.5
    scale.lineCapStyle = .round
    scale.appendArc(withCenter: c, radius: 8, startAngle: -50, endAngle: 230)
    color.setStroke()
    scale.stroke()
    return true
  }
  image.isTemplate = true // follows the menu bar's light or dark tint
  image.accessibilityDescription = bright ? "Knob, Claude voice on" : "Knob, Claude voice off"
  return image
}

final class App: NSObject, NSApplicationDelegate {
  let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  let popover = NSPopover()
  let voiceButton = NSButton()
  let stack = NSStackView()
  let icons = [false: menuIcon(bright: false), true: menuIcon(bright: true)]

  var isOn: Bool { FileManager.default.fileExists(atPath: flag) }

  func applicationDidFinishLaunching(_ note: Notification) {
    voiceButton.isBordered = false
    voiceButton.wantsLayer = true
    voiceButton.layer?.cornerRadius = 18
    voiceButton.target = self
    voiceButton.action = #selector(toggle)
    voiceButton.image = spark(size: 30, color: .white)
    voiceButton.imagePosition = .imageLeading
    voiceButton.imageHugsTitle = true
    voiceButton.heightAnchor.constraint(equalToConstant: 76).isActive = true

    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16)
    stack.widthAnchor.constraint(equalToConstant: 300).isActive = true
    stack.addArrangedSubview(voiceButton)
    stack.setCustomSpacing(18, after: voiceButton)
    let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
    quit.bezelStyle = .inline
    stack.addArrangedSubview(quit)
    voiceButton.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
    popover.contentViewController = NSViewController()
    popover.contentViewController!.view = stack
    popover.behavior = .transient

    item.button?.target = self
    item.button?.action = #selector(showPopover)

    refresh()
  }

  @objc func showPopover() {
    refresh() // the voice flag may have changed from a terminal
    popover.show(relativeTo: item.button!.bounds, of: item.button!, preferredEdge: .minY)
  }

  @objc func toggle() {
    if isOn {
      try? FileManager.default.removeItem(atPath: flag)
      // Cut off anything already being summarized or spoken.
      let kill = Process()
      kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
      kill.arguments = ["-f", "voice-reply.sh (summarize|play)|hooks/mic-watch"]
      try? kill.run()
    } else {
      FileManager.default.createFile(atPath: flag, contents: nil)
    }
    refresh()
  }

  func refresh() {
    let on = isOn
    item.button?.image = icons[on]
    voiceButton.attributedTitle = NSAttributedString(string: on ? "  Claude speaks" : "  Claude silent", attributes: [
      .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 22, weight: .semibold)])
    voiceButton.layer?.backgroundColor = (on ? claudeOrange : NSColor.systemGray).cgColor
    popover.contentSize = stack.fittingSize
  }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
