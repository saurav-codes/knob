// Knob: a tiny menu bar utility. A switch for Claude's spoken replies, speaker and mic priority lists,
// and an F5 mic mute key. The voice hook speaks only while ~/.claude/voice-reply exists.
// Audio work runs only when CoreAudio reports a device change, and the mute key is a system hotkey; nothing polls.
import AppKit
import Carbon.HIToolbox
import CoreAudio

let flag = NSHomeDirectory() + "/.claude/voice-reply"
let accent = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
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

// The F5 dictation key sends HID consumer usage 0xCF. Remapping it to F20 stops dictation and lets
// a plain Carbon hotkey catch it, which needs no Accessibility or Input Monitoring permission.
func remapDictationKey(_ on: Bool) {
  let mapping = on ? "[{\"HIDKeyboardModifierMappingSrc\":0xC000000CF,\"HIDKeyboardModifierMappingDst\":0x70000006F}]" : "[]"
  let hidutil = Process()
  hidutil.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
  hidutil.arguments = ["property", "--set", "{\"UserKeyMapping\":\(mapping)}"]
  hidutil.standardOutput = FileHandle.nullDevice
  try? hidutil.run()
  hidutil.waitUntilExit()
}

var onMuteKey: () -> Void = {}

// Big mic icon shown on the laptop screen for a moment after each mute key press.
final class MuteHUD {
  let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
  let icon = NSImageView(frame: NSRect(x: 50, y: 62, width: 100, height: 100))
  let label = NSTextField(labelWithString: "")
  var shownAt = Date.distantPast

  init() {
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .screenSaver
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    let blur = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
    blur.material = .hudWindow
    blur.state = .active
    blur.wantsLayer = true
    blur.layer?.cornerRadius = 28
    icon.symbolConfiguration = .init(pointSize: 76, weight: .medium)
    label.frame = NSRect(x: 0, y: 24, width: 200, height: 26)
    label.alignment = .center
    label.font = .systemFont(ofSize: 20, weight: .semibold)
    blur.addSubview(icon)
    blur.addSubview(label)
    panel.contentView = blur
  }

  func show(muted: Bool?) {
    icon.image = NSImage(systemSymbolName: muted == false ? "mic.fill" : "mic.slash.fill", accessibilityDescription: nil)
    icon.contentTintColor = muted == true ? .systemRed : .labelColor
    label.stringValue = muted.map { $0 ? "Mic muted" : "Mic on" } ?? "Can't mute this mic"
    // The built-in display, or the main one when the lid is closed.
    let builtIn = NSScreen.screens.first {
      CGDisplayIsBuiltin(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value) != 0
    }
    guard let screen = builtIn ?? NSScreen.main else { return }
    panel.setFrameOrigin(NSPoint(x: screen.frame.midX - 100, y: screen.frame.minY + 120))
    panel.alphaValue = 1
    panel.orderFrontRegardless()
    let stamp = Date()
    shownAt = stamp
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      guard let self, self.shownAt == stamp else { return } // a newer press keeps it up
      NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self.panel.animator().alphaValue = 0 }) {
        if self.shownAt == stamp { self.panel.orderOut(nil) }
      }
    }
  }
}

final class PointerSegments: NSSegmentedControl {
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class PointerButton: NSButton {
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// A big square switch in the style of Control Center: icon, name, and its state in words.
final class Tile: NSButton {
  let icon = NSImageView()
  let name = NSTextField(labelWithString: "")
  let detail = NSTextField(labelWithString: "")

  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
  override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil } // labels never eat the click

  convenience init(target: AnyObject, action: Selector) {
    self.init(frame: .zero)
    self.target = target
    self.action = action
    title = ""
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 16
    heightAnchor.constraint(equalToConstant: 104).isActive = true
    // Every icon gets the same fixed box, so both tiles line up whatever the glyph.
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 30).isActive = true
    name.font = .systemFont(ofSize: 14, weight: .semibold)
    detail.font = .systemFont(ofSize: 12, weight: .medium)
    let column = NSStackView(views: [icon, name, detail])
    column.orientation = .vertical
    column.spacing = 2
    column.setCustomSpacing(10, after: icon)
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(column)
    column.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
    column.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
  }

  // fill nil means the switch is in its resting state. image must be a template so it takes the ink.
  func show(image: NSImage, title: String, state text: String, fill: NSColor?) {
    let ink: NSColor = fill == nil ? .labelColor : .white
    icon.image = image
    icon.contentTintColor = ink
    name.stringValue = title
    name.textColor = ink
    detail.stringValue = text
    detail.textColor = ink.withAlphaComponent(0.75)
    layer?.backgroundColor = (fill ?? NSColor.labelColor.withAlphaComponent(0.08)).cgColor
  }
}

func sectionHeader(_ title: String, hint: String? = nil) -> NSTextField {
  let text = NSMutableAttributedString(string: title, attributes: [
    .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
  if let hint {
    text.append(NSAttributedString(string: "   \(hint)", attributes: [
      .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
  }
  return NSTextField(labelWithAttributedString: text)
}

final class PointerTable: NSTableView {
  override func resetCursorRects() { addCursorRect(visibleRect, cursor: .pointingHand) }
}

// One ranked device list. Drag a row to reorder, or click it to make it first.
final class DeviceList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  static let rowHeight: CGFloat = 38
  let kind: Kind
  let table = PointerTable()
  let scroll = NSScrollView()
  let height: NSLayoutConstraint
  let onChange: () -> Void
  var order: [String] = []
  var connected: [String: AudioDeviceID] = [:]
  var current = AudioDeviceID(0)
  var names: [String: String] = [:]

  init(kind: Kind, onChange: @escaping () -> Void) {
    self.kind = kind
    self.onChange = onChange
    height = scroll.heightAnchor.constraint(equalToConstant: 0)
    super.init()
    table.addTableColumn(NSTableColumn())
    table.headerView = nil
    table.style = .plain
    table.backgroundColor = .clear
    table.selectionHighlightStyle = .none
    table.rowHeight = Self.rowHeight
    table.intercellSpacing = NSSize(width: 0, height: 4)
    table.registerForDraggedTypes([.string])
    table.setDraggingSourceOperationMask(.move, forLocal: true)
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(clicked)
    scroll.documentView = table
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = false
    height.isActive = true
  }

  func reload(names: [String: String]) {
    self.names = names
    order = kind.order
    connected = kind.connected()
    current = kind.defaultDevice
    table.reloadData()
    height.constant = CGFloat(order.count) * (Self.rowHeight + 4)
  }

  func move(from: Int, to: Int) {
    var newOrder = order
    newOrder.insert(newOrder.remove(at: from), at: to)
    kind.order = newOrder
    onChange()
  }

  @objc func clicked() {
    if table.clickedRow > 0 { move(from: table.clickedRow, to: 0) }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { order.count }

  func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
    let uid = order[row]
    let id = connected[uid]
    let active = id != nil && id == current
    let ink: NSColor = active ? .white : id == nil ? .tertiaryLabelColor : .labelColor

    let rank = NSTextField(labelWithString: "\(row + 1)")
    rank.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    rank.textColor = active ? .white : .secondaryLabelColor

    let name = NSTextField(labelWithString: names[uid] ?? uid)
    name.font = .systemFont(ofSize: 14, weight: active ? .semibold : .regular)
    name.textColor = ink
    name.lineBreakMode = .byTruncatingTail
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    // State in words, not only color.
    let status = NSTextField(labelWithString: active ? "In use" : id == nil ? "Not connected" : "")
    status.font = .systemFont(ofSize: 11, weight: .medium)
    status.textColor = active ? .white.withAlphaComponent(0.85) : .tertiaryLabelColor

    // Grip so it is obvious the row can be dragged.
    let grip = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag")!)
    grip.contentTintColor = active ? .white.withAlphaComponent(0.7) : .tertiaryLabelColor

    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    let cell = NSStackView(views: [rank, name, spacer, status, grip])
    cell.spacing = 10
    cell.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
    cell.wantsLayer = true
    cell.layer?.cornerRadius = 10
    cell.layer?.backgroundColor = (active ? accent : NSColor.labelColor.withAlphaComponent(0.06)).cgColor
    return cell
  }

  func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
    String(row) as NSString
  }

  func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                 proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
    guard info.draggingSource as? NSTableView === table else { return [] } // no drags between the two lists
    tableView.setDropRow(row, dropOperation: .above)
    return .move
  }

  func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                 dropOperation: NSTableView.DropOperation) -> Bool {
    guard let from = info.draggingPasteboard.string(forType: .string).flatMap(Int.init) else { return false }
    move(from: from, to: row > from ? row - 1 : row)
    return true
  }
}

final class App: NSObject, NSApplicationDelegate, NSPopoverDelegate {
  let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  let popover = NSPopover()
  let sparkTemplate: NSImage = {
    let image = spark(size: 30, color: .black)
    image.isTemplate = true
    return image
  }()
  lazy var voiceTile = Tile(target: self, action: #selector(toggle))
  lazy var micTile = Tile(target: self, action: #selector(toggleMicFromPanel))
  let stack = NSStackView()
  let icons = [false: menuIcon(bright: false), true: menuIcon(bright: true)]
  var lists: [DeviceList] = []
  let f5Mode = PointerSegments(labels: ["Dictation", "Mute mic"], trackingMode: .selectOne, target: nil, action: nil)
  lazy var hud = MuteHUD()
  var hotKeys: [EventHotKeyRef?] = []
  var mutedMic: AudioDeviceID? // set while Knob holds the mic muted, so the mute can follow a device switch
  var outsideClicks: Any?
  var names: [String: String] {
    get { UserDefaults.standard.dictionary(forKey: "names") as? [String: String] ?? [:] }
    set { UserDefaults.standard.set(newValue, forKey: "names") }
  }

  var isOn: Bool { FileManager.default.fileExists(atPath: flag) }

  func applicationDidFinishLaunching(_ note: Notification) {
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
    stack.widthAnchor.constraint(equalToConstant: 340).isActive = true

    let tiles = NSStackView(views: [voiceTile, micTile])
    tiles.distribution = .fillEqually
    tiles.spacing = 10
    stack.addArrangedSubview(tiles)
    stack.setCustomSpacing(20, after: tiles)

    for kind in kinds {
      let header = sectionHeader(kind.title, hint: "Drag to set the order")
      let list = DeviceList(kind: kind) { [weak self] in self?.applyPriority() }
      lists.append(list)
      stack.addArrangedSubview(header)
      stack.addArrangedSubview(list.scroll)
      stack.setCustomSpacing(18, after: list.scroll)
    }

    f5Mode.controlSize = .large
    f5Mode.font = .systemFont(ofSize: 14)
    f5Mode.segmentDistribution = .fillEqually
    f5Mode.target = self
    f5Mode.action = #selector(changeF5Mode)
    f5Mode.selectedSegment = UserDefaults.standard.bool(forKey: "f5Mute") ? 1 : 0
    let f5Header = sectionHeader("F5 key", hint: "The 🎤 key on Mac laptops")
    stack.addArrangedSubview(f5Header)
    stack.addArrangedSubview(f5Mode)
    stack.setCustomSpacing(20, after: f5Mode)

    let quit = PointerButton(title: "Quit Knob", target: NSApp, action: #selector(NSApplication.terminate(_:)))
    quit.isBordered = false
    quit.contentTintColor = .secondaryLabelColor
    quit.font = .systemFont(ofSize: 12)
    stack.addArrangedSubview(quit)
    for view in [tiles, f5Mode] + lists.map(\.scroll) {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
    }
    popover.contentViewController = NSViewController()
    popover.contentViewController!.view = stack
    popover.behavior = .transient
    popover.delegate = self

    item.button?.target = self
    item.button?.action = #selector(togglePopover)

    // macOS switches to whatever was plugged in last; put our pick back on every device or default change.
    for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                     kAudioHardwarePropertyDefaultInputDevice] {
      var addr = address(selector)
      AudioObjectAddPropertyListenerBlock(system, &addr, .main) { [weak self] _, _ in self?.applyPriority() }
    }
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in onMuteKey(); return noErr }, 1, &spec, nil, nil)
    onMuteKey = { [weak self] in self?.toggleMic() }
    applyF5Mode()
    applyPriority()
  }

  func applicationWillTerminate(_ notification: Notification) {
    if !hotKeys.isEmpty { remapDictationKey(false) } // give F5 back to dictation
  }

  @objc func changeF5Mode() {
    UserDefaults.standard.set(f5Mode.selectedSegment == 1, forKey: "f5Mute")
    applyF5Mode()
  }

  func applyF5Mode() {
    let mute = UserDefaults.standard.bool(forKey: "f5Mute")
    // Only touch the key mapping when Knob owns it, so dictation mode leaves other mappings alone.
    if mute || !hotKeys.isEmpty { remapDictationKey(mute) }
    if mute, hotKeys.isEmpty {
      // Keyboards may or may not flag a function key with fn, and Carbon matches modifiers exactly.
      hotKeys = [0, UInt32(kEventKeyModifierFnMask)].map { modifiers in
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_F20), modifiers, EventHotKeyID(signature: 0x4B4E4F42, id: modifiers),
                            GetApplicationEventTarget(), 0, &ref)
        return ref
      }
    } else if !mute, !hotKeys.isEmpty {
      hotKeys.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
      hotKeys = []
    }
  }

  // nil when the device has no settable mute control.
  func isMuted(_ id: AudioDeviceID) -> Bool? {
    var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput)
    var value = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value != 0
  }

  func setMuted(_ id: AudioDeviceID, _ muted: Bool) -> Bool {
    var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput)
    var value = UInt32(muted ? 1 : 0)
    return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
  }

  @objc func toggleMicFromPanel() { toggleMic() }

  func toggleMic() {
    // Read the device, not a cached flag: System Settings or a call app may have changed it.
    let mic = kinds[1].defaultDevice
    guard let muted = isMuted(mic), setMuted(mic, !muted) else { return hud.show(muted: nil) }
    mutedMic = muted ? nil : mic
    hud.show(muted: !muted)
    refresh()
  }

  // Sets each default to the highest ranked connected device. Writes only on a real change,
  // so it can't loop with CoreAudio and doesn't touch disk on every event.
  func applyPriority() {
    for kind in kinds {
      let connected = kind.connected()
      let current = kind.defaultDevice
      var order = kind.order
      // New devices rank last, except the current default leads on first sight so first launch changes nothing.
      let unseen = connected.keys.filter { !order.contains($0) }.sorted { a, _ in connected[a] == current }
      if !unseen.isEmpty {
        order += unseen
        kind.order = order
        names = names.merging(unseen.map { ($0, string(connected[$0]!, kAudioObjectPropertyName) ?? $0) }) { $1 }
      }
      if let best = order.first(where: { connected[$0] != nil }), connected[best] != current {
        kind.defaultDevice = connected[best]!
      }
    }
    // Mute follows you to whichever mic becomes the default, unless it was unmuted elsewhere meanwhile.
    let mic = kinds[1].defaultDevice
    if let old = mutedMic, old != mic {
      mutedMic = isMuted(old) != false && setMuted(mic, true) ? mic : nil
    }
    refresh()
  }

  @objc func togglePopover() {
    if popover.isShown { return popover.performClose(nil) }
    refresh(full: true) // the voice flag may have changed from a terminal
    popover.show(relativeTo: item.button!.bounds, of: item.button!, preferredEdge: .minY)
    // A menu bar app is never the active app, so .transient alone misses clicks in other apps.
    outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      self?.popover.performClose(nil)
    }
  }

  func popoverDidClose(_ notification: Notification) {
    if let monitor = outsideClicks { NSEvent.removeMonitor(monitor) }
    outsideClicks = nil
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

  // Device lists are rebuilt only when visible; a closed popover costs nothing on audio events.
  func refresh(full: Bool = false) {
    let on = isOn
    item.button?.image = icons[on]
    guard full || popover.isShown else { return }
    voiceTile.show(image: sparkTemplate, title: "Claude voice",
                   state: on ? "Speaks replies" : "Silent", fill: on ? accent : nil)
    let muted = isMuted(kinds[1].defaultDevice)
    let symbol = NSImage(systemSymbolName: muted == false ? "mic.fill" : "mic.slash.fill", accessibilityDescription: nil)!
    micTile.show(image: symbol, title: "Microphone", state: muted.map { $0 ? "Muted" : "Live" } ?? "Can't mute",
                 fill: muted == true ? .systemRed : nil)
    lists.forEach { $0.reload(names: names) }
    popover.contentSize = stack.fittingSize
  }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// launchctl and logout send SIGTERM; quit normally so F5 gets its dictation mapping back.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { app.terminate(nil) }
sigterm.resume()
app.run()
