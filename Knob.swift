// Knob: a tiny notch utility. A switch for Claude's spoken replies, speaker and mic priority lists,
// an external display scale slider, and an F5 mic mute key. The voice hook speaks only while ~/.claude/voice-reply exists.
// Audio work runs only when CoreAudio reports a device change, and the mute key is a system hotkey; nothing polls.
import AppKit
import Carbon.HIToolbox
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

  // Devices never to switch to, such as a headset's poor mic. Kept per kind, since a headset's
  // speakers and mic share one UID. Stored order keeps them after every device still in use.
  var off: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: key + "Off") ?? []) }
    nonmutating set { UserDefaults.standard.set(newValue.sorted(), forKey: key + "Off") }
  }
}

let kinds = [
  Kind(title: "Speakers", defaultSelector: kAudioHardwarePropertyDefaultOutputDevice,
       scope: kAudioObjectPropertyScopeOutput, key: "output"),
  Kind(title: "Microphone", defaultSelector: kAudioHardwarePropertyDefaultInputDevice,
       scope: kAudioObjectPropertyScopeInput, key: "input"),
]

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

// Every button lights up under the pointer, so it is obvious what a click will hit.
class HoverButton: NSButton {
  var hovering = false { didSet { if hovering != oldValue { restyle() } } }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self))
  }

  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }

  func restyle() {}
}

// A closed panel gets no exit events, so it forgets every hover when it hides.
func clearHover(_ view: NSView) {
  (view as? HoverButton)?.hovering = false
  (view as? RowCell)?.hovering = false
  view.subviews.forEach(clearHover)
}

// A round icon button, such as ⊖ on a device or ⏹ on a port.
final class IconButton: HoverButton {
  convenience init(symbol: String, label: String, target: AnyObject, action: Selector) {
    self.init(frame: .zero)
    self.target = target
    self.action = action
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    symbolConfiguration = .init(pointSize: 15, weight: .regular)
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 15
    widthAnchor.constraint(equalToConstant: 30).isActive = true
    heightAnchor.constraint(equalToConstant: 30).isActive = true
    restyle()
  }

  override func restyle() {
    contentTintColor = hovering ? .labelColor : .secondaryLabelColor
    layer?.backgroundColor = hovering ? NSColor.labelColor.withAlphaComponent(0.15).cgColor : nil
  }
}

// Small text for rare actions such as Quit. It brightens under the pointer.
final class TextButton: HoverButton {
  var text = ""

  convenience init(_ text: String, target: AnyObject, action: Selector) {
    self.init(frame: .zero)
    self.text = text
    self.target = target
    self.action = action
    isBordered = false
    restyle()
  }

  override func restyle() {
    attributedTitle = NSAttributedString(string: text, attributes: [
      .font: NSFont.systemFont(ofSize: 11), .foregroundColor: hovering ? NSColor.labelColor : .tertiaryLabelColor])
  }
}

// A big rounded button. The selected one turns solid white, like an active switch in Control Center.
final class Pill: HoverButton {
  var selected = false { didSet { restyle() } }
  var text = ""

  convenience init(_ text: String, target: AnyObject, action: Selector) {
    self.init(frame: .zero)
    self.text = text
    self.target = target
    self.action = action
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 12
    heightAnchor.constraint(equalToConstant: 40).isActive = true
    restyle()
  }

  override func restyle() {
    let ink: NSColor = selected ? .black : .labelColor
    attributedTitle = NSAttributedString(string: text, attributes: [
      .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium), .foregroundColor: ink])
    let rest = NSColor.labelColor.withAlphaComponent(hovering ? 0.18 : 0.1)
    layer?.backgroundColor = (selected ? NSColor.white.withAlphaComponent(hovering ? 1 : 0.92) : rest).cgColor
  }
}

// A big square switch in the style of Control Center: icon, name, and its state in words.
final class Tile: HoverButton {
  let icon = NSImageView()
  let name = NSTextField(labelWithString: "")
  let detail = NSTextField(labelWithString: "")
  var fill: NSColor?

  override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil } // labels never eat the click

  convenience init(target: AnyObject, action: Selector) {
    self.init(frame: .zero)
    self.target = target
    self.action = action
    title = ""
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 22
    heightAnchor.constraint(equalToConstant: 108).isActive = true
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
    self.fill = fill
    restyle()
  }

  override func restyle() {
    let color = fill.map { hovering ? $0.blended(withFraction: 0.12, of: .white)! : $0 }
      ?? NSColor.labelColor.withAlphaComponent(hovering ? 0.16 : 0.1)
    layer?.backgroundColor = color.cgColor
  }
}

// A Control Center style slider: a thick pill with a handle that fills from the left and snaps to stops. It reports
// the stop on release, since every display mode change blanks the screen for a moment.
final class PillSlider: NSView {
  var count = 2 { didSet { needsDisplay = true } }
  var index = 0 { didSet { needsDisplay = true } }
  var onMove: (Int) -> Void = { _ in }
  var onRelease: (Int) -> Void = { _ in }

  static let iconSpace: CGFloat = 26 // room for the small and large A outside the track

  override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 34) }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

  func glyph(_ symbol: String, size: CGFloat) -> NSImage {
    NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
      .withSymbolConfiguration(.init(pointSize: size, weight: .semibold)
        .applying(.init(paletteColors: [.secondaryLabelColor])))!
  }

  var trackRect: NSRect { bounds.insetBy(dx: Self.iconSpace, dy: 0) }

  // Where stop i sits: the center of the handle.
  func x(of i: Int) -> CGFloat {
    let track = trackRect, r = track.height / 2
    return track.minX + r + (track.width - 2 * r) * CGFloat(i) / CGFloat(max(count - 1, 1))
  }

  override func draw(_ dirtyRect: NSRect) {
    let track = trackRect, r = track.height / 2
    NSColor.labelColor.withAlphaComponent(0.12).setFill()
    NSBezierPath(roundedRect: track, xRadius: r, yRadius: r).fill()
    let handle = x(of: index)
    NSColor.white.withAlphaComponent(0.45).setFill()
    NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: handle + r - track.minX, height: track.height),
                 xRadius: r, yRadius: r).fill()
    // A dot for each stop ahead, so you can see where it will snap.
    NSColor.labelColor.withAlphaComponent(0.35).setFill()
    for i in index + 1 ..< max(count, index + 1) {
      NSBezierPath(ovalIn: NSRect(x: x(of: i) - 2.5, y: r - 2.5, width: 5, height: 5)).fill()
    }
    // The handle you grab: a solid white circle that floats on a soft shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 4
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: handle - r + 3, y: track.minY + 3, width: 2 * r - 6, height: 2 * r - 6)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let small = glyph("textformat.size.smaller", size: 12)
    small.draw(in: NSRect(x: (Self.iconSpace - small.size.width) / 2 - 2, y: r - small.size.height / 2,
                          width: small.size.width, height: small.size.height))
    let large = glyph("textformat.size.larger", size: 16)
    large.draw(in: NSRect(x: bounds.width - (Self.iconSpace + large.size.width) / 2 + 2, y: r - large.size.height / 2,
                          width: large.size.width, height: large.size.height))
  }

  func track(_ event: NSEvent) {
    let px = convert(event.locationInWindow, from: nil).x
    index = (0 ..< count).min { abs(x(of: $0) - px) < abs(x(of: $1) - px) } ?? 0
    onMove(index)
  }

  override func mouseDown(with event: NSEvent) {
    NSCursor.closedHand.push()
    track(event)
  }

  override func mouseDragged(with event: NSEvent) { track(event) }

  override func mouseUp(with event: NSEvent) {
    NSCursor.pop()
    track(event)
    onRelease(index)
  }
}

func headerText(_ title: String, hint: String? = nil) -> NSAttributedString {
  let text = NSMutableAttributedString(string: title, attributes: [
    .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
  if let hint {
    text.append(NSAttributedString(string: "   \(hint)", attributes: [
      .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
  }
  return text
}

func sectionHeader(_ title: String) -> NSTextField {
  NSTextField(labelWithAttributedString: headerText(title))
}

// A section title that shows or hides the section below it, with a chevron at the right edge.
final class Disclosure: HoverButton {
  let label = NSTextField(labelWithString: "")
  let chevron = NSImageView()

  override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

  convenience init(target: AnyObject, action: Selector) {
    self.init(frame: .zero)
    self.target = target
    self.action = action
    title = ""
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 12
    chevron.contentTintColor = .secondaryLabelColor
    let row = NSStackView(views: [label, NSView(), chevron])
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 40),
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    restyle()
  }

  override func restyle() {
    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(hovering ? 0.16 : 0.08).cgColor
  }

  func show(_ text: NSAttributedString, expanded: Bool) {
    label.attributedStringValue = text
    chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                            accessibilityDescription: expanded ? "Collapse" : "Expand")
    setAccessibilityLabel(text.string)
  }
}

// Inner lists never scroll themselves, so the wheel goes to the panel's own scroll view. Rows sit straight
// on the glass, with a little inset so the pill of the row in use has room.
final class PassScroll: NSScrollView {
  static let inset: CGFloat = 4

  override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }

  func styleAsList() {
    drawsBackground = false
    hasVerticalScroller = false
    automaticallyAdjustsContentInsets = false
    contentInsets = NSEdgeInsets(top: Self.inset, left: 0, bottom: Self.inset, right: 0)
  }
}

// A list row: the device in use gets a soft pill, and any row lights up under the pointer.
final class RowCell: NSStackView {
  var highlighted = false { didSet { restyle() } }
  var hovering = false { didSet { restyle() } }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self))
  }

  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }

  func restyle() {
    let alpha: CGFloat = highlighted ? 0.14 : hovering ? 0.07 : 0
    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
  }
}

func rowCell(_ views: [NSView], highlighted: Bool = false) -> RowCell {
  let cell = RowCell(views: views)
  cell.spacing = 8
  cell.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 6)
  cell.wantsLayer = true
  cell.layer?.cornerRadius = 12
  cell.highlighted = highlighted
  return cell
}

// Takes clicks and keys without making Knob the active app.
final class FloatingPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

// Reports the pointer entering and leaving, with no polling.
final class HoverView: NSView {
  var onEnter: () -> Void = {}
  var onExit: () -> Void = {}

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self))
  }

  override func mouseEntered(with event: NSEvent) { onEnter() }
  override func mouseExited(with event: NSEvent) { onExit() }
}

// Top-down document for the panel's scroll view, so a short panel starts at the top.
final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

final class PointerTable: NSTableView {
  override func resetCursorRects() { addCursorRect(visibleRect, cursor: .pointingHand) }
}

// One ranked device list. Drag a row to reorder, or click it to make it first.
final class DeviceList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  static let rowHeight: CGFloat = 40
  let kind: Kind
  let table = PointerTable()
  let scroll = PassScroll()
  let height: NSLayoutConstraint
  let onChange: () -> Void
  var order: [String] = []
  var connected: [String: AudioDeviceID] = [:]
  var current = AudioDeviceID(0)
  var names: [String: String] = [:]
  var off: Set<String> = []
  var inUse: Int { order.count - off.count } // rows above the "never use" ones

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
    table.intercellSpacing = NSSize(width: 0, height: 2)
    table.toolTip = "Drag to set the order. Knob uses the first one that is connected."
    table.registerForDraggedTypes([.string])
    table.setDraggingSourceOperationMask(.move, forLocal: true)
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(clicked)
    scroll.documentView = table
    scroll.styleAsList()
    height.isActive = true
  }

  func reload(names: [String: String]) {
    self.names = names
    order = kind.order
    off = kind.off
    connected = kind.connected()
    current = kind.defaultDevice
    table.reloadData()
    height.constant = CGFloat(order.count) * (Self.rowHeight + 2) + PassScroll.inset * 2
  }

  func move(from: Int, to: Int) {
    var newOrder = order
    newOrder.insert(newOrder.remove(at: from), at: to)
    kind.order = newOrder
    onChange()
  }

  @objc func clicked() {
    if table.clickedRow > 0, table.clickedRow < inUse { move(from: table.clickedRow, to: 0) }
  }

  // Never use a device, or use it again at the bottom of the ranking.
  @objc func toggleUse(_ sender: NSButton) {
    let uid = order[sender.tag]
    var newOrder = order.filter { $0 != uid }
    if off.contains(uid) {
      newOrder.insert(uid, at: inUse)
      kind.off = off.subtracting([uid])
    } else {
      newOrder.append(uid)
      kind.off = off.union([uid])
    }
    kind.order = newOrder
    onChange()
  }

  func numberOfRows(in tableView: NSTableView) -> Int { order.count }

  func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
    let uid = order[row]
    let id = connected[uid]
    let unused = off.contains(uid)
    let active = id != nil && id == current && !unused
    let dim = id == nil || unused

    let check = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: "In use")!)
    check.symbolConfiguration = .init(pointSize: 12, weight: .bold)
    check.contentTintColor = .labelColor
    check.alphaValue = active ? 1 : 0 // keeps its space, so names line up
    check.widthAnchor.constraint(equalToConstant: 14).isActive = true

    let name = NSTextField(labelWithString: names[uid] ?? uid)
    name.font = .systemFont(ofSize: 13, weight: active ? .semibold : .regular)
    name.textColor = dim ? .tertiaryLabelColor : .labelColor
    name.lineBreakMode = .byTruncatingTail
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    // State in words, not only the checkmark.
    let status = NSTextField(labelWithString: unused ? "Never used" : active ? "In use" : id == nil ? "Not connected" : "")
    status.font = .systemFont(ofSize: 11)
    status.textColor = .tertiaryLabelColor

    let use = IconButton(symbol: unused ? "plus.circle" : "minus.circle", label: unused ? "Use again" : "Never use",
                         target: self, action: #selector(toggleUse(_:)))
    use.tag = row
    use.toolTip = unused ? "Use this device again" : "Never use this device"

    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    let cell = rowCell([check, name, spacer, status, use], highlighted: active)
    return cell
  }

  func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
    row < inUse ? String(row) as NSString : nil
  }

  func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                 proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
    guard info.draggingSource as? NSTableView === table else { return [] } // no drags between the two lists
    tableView.setDropRow(min(row, inUse), dropOperation: .above)
    return .move
  }

  func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                 dropOperation: NSTableView.DropOperation) -> Bool {
    guard let from = info.draggingPasteboard.string(forType: .string).flatMap(Int.init) else { return false }
    move(from: from, to: row > from ? row - 1 : row)
    return true
  }
}

// A process listening on a TCP port, such as a dev server an agent started and forgot.
struct Listener {
  let port: Int
  let pid: pid_t
  let name: String
  let cwd: String
  let started: Date
}

func cwd(of pid: pid_t) -> String {
  var info = proc_vnodepathinfo()
  guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return "" }
  return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

func startTime(of pid: pid_t) -> Date {
  var info = proc_bsdinfo()
  proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
  return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
}

// Your listening TCP ports, minus macOS's own services such as AirPlay, which live under /System and /usr.
func scanPorts() -> [Listener] {
  let lsof = Process()
  let out = Pipe()
  lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
  lsof.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]
  lsof.standardOutput = out
  lsof.standardError = FileHandle.nullDevice
  guard (try? lsof.run()) != nil else { return [] }
  let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  lsof.waitUntilExit()
  var found: [String: Listener] = [:] // one row per process and port, though IPv4 and IPv6 each listen
  var pid: pid_t = 0
  var name = ""
  var system = false
  for line in text.split(separator: "\n") {
    let value = String(line.dropFirst())
    switch line.first {
    case "p":
      pid = pid_t(value) ?? 0
      var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
      proc_pidpath(pid, &path, UInt32(path.count))
      let exe = String(cString: path)
      system = exe.hasPrefix("/System/") || exe.hasPrefix("/usr/")
    case "c": name = value
    case "n":
      guard !system, let port = value.split(separator: ":").last.flatMap({ Int($0) }) else { continue }
      found["\(pid):\(port)"] = found["\(pid):\(port)"] ??
        Listener(port: port, pid: pid, name: name, cwd: cwd(of: pid), started: startTime(of: pid))
    default: break
    }
  }
  return found.values.sorted { $0.port < $1.port }
}

// Open ports, collapsed under a title that counts them. Click a row to open it in the browser,
// or stop the process that holds it.
final class PortList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  static let rowHeight: CGFloat = 40
  lazy var header = Disclosure(target: self, action: #selector(toggleExpanded))
  var expanded = false
  let table = PointerTable()
  let scroll = PassScroll()
  let empty = NSTextField(labelWithString: "Nothing is listening")
  let height: NSLayoutConstraint
  let onChange: () -> Void
  var ports: [Listener] = []
  let age: DateComponentsFormatter = {
    let format = DateComponentsFormatter()
    format.unitsStyle = .abbreviated
    format.maximumUnitCount = 1
    format.allowedUnits = [.day, .hour, .minute]
    return format
  }()

  init(onChange: @escaping () -> Void) {
    self.onChange = onChange
    height = scroll.heightAnchor.constraint(equalToConstant: 0)
    super.init()
    table.addTableColumn(NSTableColumn())
    table.headerView = nil
    table.style = .plain
    table.backgroundColor = .clear
    table.selectionHighlightStyle = .none
    table.rowHeight = Self.rowHeight
    table.intercellSpacing = NSSize(width: 0, height: 2)
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(clicked)
    scroll.documentView = table
    scroll.styleAsList()
    height.isActive = true
    empty.font = .systemFont(ofSize: 13)
    empty.textColor = .tertiaryLabelColor
    update()
  }

  func update() {
    let count = ports.count
    header.show(headerText("Open ports", hint: count == 0 ? "None running" : "\(count) running"), expanded: expanded)
    scroll.isHidden = !expanded || ports.isEmpty
    (header.superview as? NSStackView)?.setCustomSpacing(expanded ? 8 : 18, after: header)
    empty.isHidden = !expanded || !ports.isEmpty
    height.constant = CGFloat(count) * (Self.rowHeight + 2) + PassScroll.inset * 2
    onChange()
  }

  @objc func toggleExpanded() {
    expanded.toggle()
    update()
    // Bring the opened list into view when the panel has to scroll.
    if expanded { DispatchQueue.main.async { self.scroll.scrollToVisible(self.scroll.bounds) } }
  }

  // lsof takes a few milliseconds, so it runs off the main thread and the panel opens at once.
  func scan() {
    DispatchQueue.global(qos: .userInitiated).async {
      let ports = scanPorts()
      DispatchQueue.main.async {
        self.ports = ports
        self.table.reloadData()
        self.update()
      }
    }
  }

  func open(_ row: Int) {
    NSWorkspace.shared.open(URL(string: "http://localhost:\(ports[row].port)")!)
  }

  @objc func clicked() {
    if table.clickedRow >= 0 { open(table.clickedRow) }
  }

  @objc func openPort(_ sender: NSButton) { open(sender.tag) }

  @objc func stop(_ sender: NSButton) {
    kill(ports[sender.tag].pid, SIGTERM)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.scan() } // give it time to exit
  }

  func numberOfRows(in tableView: NSTableView) -> Int { ports.count }

  func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
    let listener = ports[row]
    let number = NSTextField(labelWithString: ":\(listener.port)")
    number.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    number.widthAnchor.constraint(equalToConstant: 56).isActive = true

    // The folder it was started in says which project it belongs to; the home folder or / says nothing.
    let folder = [NSHomeDirectory(), "/"].contains(listener.cwd) ? "" : (listener.cwd as NSString).lastPathComponent
    let name = NSTextField(labelWithString: folder.isEmpty ? listener.name : "\(listener.name) · \(folder)")
    name.font = .systemFont(ofSize: 13)
    name.textColor = .secondaryLabelColor
    name.lineBreakMode = .byTruncatingTail
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let uptime = Date().timeIntervalSince(listener.started)
    let since = NSTextField(labelWithString: uptime < 60 ? "Just now" : age.string(from: uptime) ?? "")
    since.font = .systemFont(ofSize: 11)
    since.textColor = .tertiaryLabelColor

    let open = IconButton(symbol: "arrow.up.forward.app", label: "Open in browser", target: self, action: #selector(openPort(_:)))
    open.toolTip = "Open localhost:\(listener.port) in your browser"
    let stop = IconButton(symbol: "stop.circle", label: "Stop", target: self, action: #selector(stop(_:)))
    stop.toolTip = "Stop \(listener.name) (PID \(listener.pid))"
    open.tag = row
    stop.tag = row

    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    let cell = rowCell([number, name, spacer, since, open, stop])
    cell.toolTip = listener.cwd.isEmpty ? nil : "Started in \(listener.cwd)"
    return cell
  }
}

// One stop on the external display's scale slider. Soft modes are drawn at 1x and stretched by the display.
struct Scale {
  let mode: CGDisplayMode
  let ratio: Double
  let sharp: Bool
}

func externalDisplay() -> CGDirectDisplayID? {
  var count = UInt32(0)
  var ids = [CGDirectDisplayID](repeating: 0, count: 16)
  CGGetOnlineDisplayList(16, &ids, &count)
  return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) == 0 }
}

// Modes with the panel's shape, from native size to twice as big, best refresh rate first.
func scales(of display: CGDirectDisplayID) -> [Scale] {
  let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
  // Under 50 Hz feels laggy, such as the 30 Hz 4K input some QHD monitors accept. Some displays report 0.
  let usable = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []).filter {
    $0.isUsableForDesktopGUI() && ($0.refreshRate == 0 || $0.refreshRate >= 50)
  }
  guard let native = usable.filter({ $0.pixelWidth == $0.width }).max(by: { $0.width < $1.width }) else { return [] }
  var best: [Int: CGDisplayMode] = [:]
  for mode in usable where mode.width * native.height == mode.height * native.width && mode.width * 2 >= native.width {
    if let old = best[mode.width], (old.pixelWidth, old.refreshRate) >= (mode.pixelWidth, mode.refreshRate) { continue }
    best[mode.width] = mode
  }
  return best.values.sorted { $0.width > $1.width }.map {
    Scale(mode: $0, ratio: Double(native.width) / Double($0.width), sharp: $0.pixelWidth >= native.width)
  }
}

// How big everything looks on the external display. Applies on release, since each change blanks the screen
// for a moment, and macOS keeps it for the next time the display is plugged in.
final class DisplayScale: NSObject {
  let value = NSTextField(labelWithString: "")
  lazy var header = NSStackView(views: [sectionHeader("External display"), NSView(), value])
  let slider = PillSlider()
  var display: CGDirectDisplayID?
  var stops: [Scale] = []
  let number: NumberFormatter = {
    let format = NumberFormatter()
    format.maximumFractionDigits = 2
    return format
  }()

  override init() {
    super.init()
    slider.onMove = { [weak self] in self?.show($0) }
    slider.onRelease = { [weak self] in self?.apply($0) }
    value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    value.textColor = .secondaryLabelColor
  }

  // Read from the system each time, so a change made in System Settings shows here too.
  func reload() {
    display = externalDisplay()
    stops = display.map(scales(of:)) ?? []
    let missing = stops.count < 2
    [header, slider].forEach { $0.isHidden = missing }
    guard !missing, let display, let current = CGDisplayCopyDisplayMode(display) else { return }
    slider.count = stops.count
    slider.index = stops.firstIndex { $0.mode.width == current.width && $0.mode.pixelWidth == current.pixelWidth }
      ?? stops.indices.min { abs(stops[$0].mode.width - current.width) < abs(stops[$1].mode.width - current.width) }!
    show(slider.index)
  }

  func show(_ index: Int) {
    let stop = stops[index]
    value.stringValue = "\(number.string(from: stop.ratio as NSNumber)!)×  " + (stop.sharp ? "Sharp" : "Soft")
    value.toolTip = "Looks like \(stop.mode.width) × \(stop.mode.height)"
  }

  func apply(_ index: Int) {
    guard let display, let current = CGDisplayCopyDisplayMode(display) else { return }
    let mode = stops[index].mode
    if mode.width == current.width, mode.pixelWidth == current.pixelWidth { return }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return }
    CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
    CGCompleteDisplayConfiguration(config, .permanently)
  }
}

final class App: NSObject, NSApplicationDelegate {
  // A glass card floats just under the notch. A black strip sits in the notch so hovering it opens the panel,
  // and the panel window spans the gap between them so the pointer can cross it.
  let notchTrigger = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: true)
  let notchPanel = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: true)
  let notchBody = HoverView()
  let glass = NSGlassEffectView()
  static let gap: CGFloat = 6
  var notch = NSRect.zero
  lazy var glassTop = glass.topAnchor.constraint(equalTo: notchBody.topAnchor)
  let sparkTemplate: NSImage = {
    let image = spark(size: 30, color: .black)
    image.isTemplate = true
    return image
  }()
  lazy var voiceTile = Tile(target: self, action: #selector(toggle))
  lazy var micTile = Tile(target: self, action: #selector(toggleMicFromPanel))
  let stack = NSStackView()
  let outer = NSScrollView()
  var lists: [DeviceList] = []
  lazy var ports = PortList { [weak self] in self?.resize() }
  var portTimer: Timer?
  let displayScale = DisplayScale()
  lazy var f5Dictation = Pill("Dictation", target: self, action: #selector(changeF5Mode(_:)))
  lazy var f5Mute = Pill("Mute mic", target: self, action: #selector(changeF5Mode(_:)))
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
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 10, right: 14)
    stack.widthAnchor.constraint(equalToConstant: 360).isActive = true

    let tiles = NSStackView(views: [voiceTile, micTile])
    tiles.distribution = .fillEqually
    tiles.spacing = 10
    stack.addArrangedSubview(tiles)
    stack.setCustomSpacing(18, after: tiles)

    for kind in kinds {
      let header = sectionHeader(kind.title)
      let list = DeviceList(kind: kind) { [weak self] in self?.applyPriority() }
      lists.append(list)
      stack.addArrangedSubview(header)
      stack.addArrangedSubview(list.scroll)
      stack.setCustomSpacing(16, after: list.scroll)
    }

    stack.addArrangedSubview(ports.header)
    stack.addArrangedSubview(ports.scroll)
    stack.addArrangedSubview(ports.empty)
    stack.setCustomSpacing(16, after: ports.scroll)
    stack.setCustomSpacing(16, after: ports.empty)

    stack.addArrangedSubview(displayScale.header)
    stack.addArrangedSubview(displayScale.slider)
    stack.setCustomSpacing(16, after: displayScale.slider)

    let f5Title = sectionHeader("F5 key")
    f5Title.toolTip = "The 🎤 key on Mac laptops"
    let f5Row = NSStackView(views: [f5Dictation, f5Mute])
    f5Row.distribution = .fillEqually
    f5Row.spacing = 8
    showF5Mode()
    stack.addArrangedSubview(f5Title)
    stack.addArrangedSubview(f5Row)
    stack.setCustomSpacing(16, after: f5Row)

    let quit = TextButton("Quit Knob", target: NSApp, action: #selector(NSApplication.terminate(_:)))
    stack.addArrangedSubview(quit)
    for view in [tiles, f5Row, ports.header, ports.scroll, displayScale.header, displayScale.slider] + lists.map(\.scroll) {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
    }
    // The panel scrolls once it would be taller than the screen.
    let document = FlippedView()
    document.translatesAutoresizingMaskIntoConstraints = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    outer.documentView = document
    outer.drawsBackground = false
    outer.hasVerticalScroller = true
    outer.autohidesScrollers = true
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: document.topAnchor),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      document.topAnchor.constraint(equalTo: outer.contentView.topAnchor),
      document.leadingAnchor.constraint(equalTo: outer.contentView.leadingAnchor),
      document.widthAnchor.constraint(equalTo: outer.contentView.widthAnchor),
    ])
    for panel in [notchTrigger, notchPanel] {
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.level = .statusBar // above the menu bar, so the panel reads as the notch growing
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }
    let strip = HoverView()
    strip.wantsLayer = true
    strip.layer?.backgroundColor = NSColor.black.cgColor
    strip.onEnter = { [weak self] in self?.showNotchPanel() }
    notchTrigger.contentView = strip
    notchBody.onExit = { [weak self] in self?.hideNotchPanelIfLeft() }
    notchPanel.contentView = notchBody
    glass.cornerRadius = 26
    glass.contentView = outer
    glass.translatesAutoresizingMaskIntoConstraints = false
    notchBody.addSubview(glass)
    NSLayoutConstraint.activate([
      glassTop,
      glass.bottomAnchor.constraint(equalTo: notchBody.bottomAnchor),
      glass.leadingAnchor.constraint(equalTo: notchBody.leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: notchBody.trailingAnchor),
    ])
    notchPanel.appearance = NSAppearance(named: .darkAqua)
    placeNotch()
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                           object: nil, queue: .main) { [weak self] _ in
      self?.placeNotch()
      self?.refresh()
    }


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

  @objc func changeF5Mode(_ sender: Pill) {
    UserDefaults.standard.set(sender === f5Mute, forKey: "f5Mute")
    showF5Mode()
    applyF5Mode()
  }

  func showF5Mode() {
    let mute = UserDefaults.standard.bool(forKey: "f5Mute")
    f5Dictation.selected = !mute
    f5Mute.selected = mute
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
      let off = kind.off
      // New devices rank last of those in use, except the current default leads on first sight so first launch
      // changes nothing.
      let unseen = connected.keys.filter { !order.contains($0) }.sorted { a, _ in connected[a] == current }
      if !unseen.isEmpty {
        order = order.filter { !off.contains($0) } + unseen + order.filter(off.contains)
        kind.order = order
        names = names.merging(unseen.map { ($0, string(connected[$0]!, kAudioObjectPropertyName) ?? $0) }) { $1 }
      }
      if let best = order.first(where: { connected[$0] != nil && !off.contains($0) }), connected[best] != current {
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

  var isShowing: Bool { notchPanel.isVisible }

  // The notch is the gap between the two usable areas at the top of a notched screen. With the lid
  // closed there is no notch, so there is nothing to hover until it opens again.
  func placeNotch() {
    guard let screen = NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil }),
          let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
      hideNotchPanel()
      notch = .zero
      return notchTrigger.orderOut(nil)
    }
    notch = NSRect(x: left.maxX, y: screen.frame.maxY - screen.safeAreaInsets.top,
                   width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
    glassTop.constant = notch.height + Self.gap
    notchTrigger.setFrame(notch, display: true)
    notchTrigger.orderFrontRegardless()
    if isShowing { resize() } // a new display scale moves the notch, and the panel should stay open under the pointer
  }

  func showNotchPanel() {
    guard !notchPanel.isVisible, notch != .zero else { return }
    willShowPanel()
    notchPanel.alphaValue = 0
    notchPanel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { $0.duration = 0.15; notchPanel.animator().alphaValue = 1 }
  }

  // Closes once the pointer is out of both the panel and the notch, unless a drag is still going.
  func hideNotchPanelIfLeft() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self, self.notchPanel.isVisible, NSEvent.pressedMouseButtons == 0 else { return }
      let mouse = NSEvent.mouseLocation
      if !self.notchPanel.frame.contains(mouse), !self.notch.contains(mouse) { self.hideNotchPanel() }
    }
  }

  func hideNotchPanel() {
    guard notchPanel.isVisible else { return }
    notchPanel.orderOut(nil)
    didHidePanel()
  }

  func willShowPanel() {
    ports.expanded = false // always opens collapsed, so the panel stays short
    refresh(full: true) // the voice flag may have changed from a terminal
    // Ports are scanned only while the panel is open, so Knob still does nothing in the background.
    ports.scan()
    portTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.ports.scan() }
    // Knob is never the active app, so only a global monitor sees clicks in other apps.
    outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      self?.hideNotchPanel()
    }
  }

  func didHidePanel() {
    clearHover(notchBody)
    if let monitor = outsideClicks { NSEvent.removeMonitor(monitor) }
    outsideClicks = nil
    portTimer?.invalidate()
    portTimer = nil
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

  // Device lists are rebuilt only when visible; a closed panel costs nothing on audio events.
  func refresh(full: Bool = false) {
    guard full || isShowing else { return }
    let on = isOn
    voiceTile.show(image: sparkTemplate, title: "Claude voice",
                   state: on ? "Speaks replies" : "Silent", fill: on ? claudeOrange : nil)
    let muted = isMuted(kinds[1].defaultDevice)
    let symbol = NSImage(systemSymbolName: muted == false ? "mic.fill" : "mic.slash.fill", accessibilityDescription: nil)!
    micTile.show(image: symbol, title: "Microphone", state: muted.map { $0 ? "Muted" : "Live" } ?? "Can't mute",
                 fill: muted == true ? .systemRed : nil)
    lists.forEach { $0.reload(names: names) }
    displayScale.reload()
    ports.update()
  }

  // As tall as the content, but never taller than the screen below the menu bar.
  func resize() {
    let fit = stack.fittingSize
    guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(notch) }) else { return }
    let height = notch.height + Self.gap + min(fit.height, screen.visibleFrame.height - 30)
    notchPanel.setFrame(NSRect(x: notch.midX - fit.width / 2, y: notch.maxY - height, width: fit.width, height: height),
                        display: true)
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
