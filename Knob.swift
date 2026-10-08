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

final class PointerButton: NSButton {
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class PointerTable: NSTableView {
  override func resetCursorRects() { addCursorRect(visibleRect, cursor: .pointingHand) }
}

// One ranked device list. Drag a row to reorder, or click it to make it first.
final class DeviceList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  static let rowHeight: CGFloat = 32
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
    let label = NSTextField(labelWithString: "\(row + 1)   \(names[uid] ?? uid)\(active ? "   ✓" : "")")
    label.font = .systemFont(ofSize: 15, weight: active ? .semibold : .regular)
    label.textColor = id == nil ? .tertiaryLabelColor : .labelColor
    label.lineBreakMode = .byTruncatingTail
    label.frame = NSRect(x: 10, y: 6, width: tableView.bounds.width - 20, height: 20)
    label.autoresizingMask = .width
    let cell = NSView()
    cell.wantsLayer = true
    cell.layer?.cornerRadius = 8
    cell.layer?.backgroundColor = active ? claudeOrange.withAlphaComponent(0.25).cgColor : nil
    cell.addSubview(label)
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
  let voiceButton = PointerButton()
  let stack = NSStackView()
  let icons = [false: menuIcon(bright: false), true: menuIcon(bright: true)]
  var lists: [DeviceList] = []
  var outsideClicks: Any?
  var names: [String: String] {
    get { UserDefaults.standard.dictionary(forKey: "names") as? [String: String] ?? [:] }
    set { UserDefaults.standard.set(newValue, forKey: "names") }
  }

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
    for kind in kinds {
      let header = NSTextField(labelWithString: "\(kind.title.uppercased())  ·  drag to reorder")
      header.font = .systemFont(ofSize: 11, weight: .semibold)
      header.textColor = .secondaryLabelColor
      let list = DeviceList(kind: kind) { [weak self] in self?.applyPriority() }
      lists.append(list)
      stack.addArrangedSubview(header)
      stack.addArrangedSubview(list.scroll)
      stack.setCustomSpacing(2, after: header)
      stack.setCustomSpacing(14, after: list.scroll)
    }
    let quit = PointerButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
    quit.bezelStyle = .inline
    stack.addArrangedSubview(quit)
    for view in [voiceButton] + lists.map(\.scroll) {
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
    applyPriority()
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
    voiceButton.attributedTitle = NSAttributedString(string: on ? "  Claude speaks" : "  Claude silent", attributes: [
      .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 22, weight: .semibold)])
    voiceButton.layer?.backgroundColor = (on ? claudeOrange : NSColor.systemGray).cgColor
    guard full || popover.isShown else { return }
    lists.forEach { $0.reload(names: names) }
    popover.contentSize = stack.fittingSize
  }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
