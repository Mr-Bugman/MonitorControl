//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  Scheduled brightness feature: timed rules that set displays to a chosen brightness.

import Cocoa
import os.log
import Settings

// MARK: - Model

enum DisplayScope: Int, Codable {
  case all = 0
  case externalOnly = 1
  case builtInOnly = 2
}

struct BrightnessSchedule: Equatable {
  var id: String = UUID().uuidString
  var enabled: Bool = true
  var hour: Int
  var minute: Int
  /// Target brightness, 0-100 (%)
  var brightness: Int
  /// Which displays this rule applies to
  var scope: DisplayScope = .all

  init(hour: Int, minute: Int, brightness: Int, scope: DisplayScope = .all) {
    self.hour = hour
    self.minute = minute
    self.brightness = brightness
    self.scope = scope
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
    self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    self.hour = try container.decode(Int.self, forKey: .hour)
    self.minute = try container.decode(Int.self, forKey: .minute)
    self.brightness = try container.decode(Int.self, forKey: .brightness)
    self.scope = try container.decodeIfPresent(DisplayScope.self, forKey: .scope) ?? .all
  }
}

extension BrightnessSchedule: Codable {
  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.id, forKey: .id)
    try container.encode(self.enabled, forKey: .enabled)
    try container.encode(self.hour, forKey: .hour)
    try container.encode(self.minute, forKey: .minute)
    try container.encode(self.brightness, forKey: .brightness)
    try container.encode(self.scope.rawValue, forKey: .scope)
  }

  private enum CodingKeys: String, CodingKey {
    case id, enabled, hour, minute, brightness, scope
  }
}

// MARK: - Scheduler

final class ScheduledBrightnessManager {
  static let shared = ScheduledBrightnessManager()

  private var timer: Timer?
  /// Keys of already fired (day, rule) combinations so a rule triggers at most once per minute match.
  private var firedKeys: Set<String> = []
  private let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  func start() {
    guard self.timer == nil else {
      return
    }
    self.timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      self?.tick()
    }
    self.tick()
  }

  func tick() {
    let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
    guard let hour = now.hour, let minute = now.minute else {
      return
    }
    let dayKey = self.dayFormatter.string(from: Date())
    for rule in ScheduledBrightnessManager.loadRules() where rule.enabled {
      let fireKey = "\(dayKey)#\(rule.id)"
      if rule.hour == hour, rule.minute == minute {
        guard !self.firedKeys.contains(fireKey) else {
          continue
        }
        self.firedKeys.insert(fireKey)
        self.applyBrightness(rule.brightness, scope: rule.scope)
      } else {
        self.firedKeys.remove(fireKey)
      }
    }
    if self.firedKeys.count > 100 {
      self.firedKeys.removeAll()
    }
  }

  func applyBrightness(_ percent: Int, scope: DisplayScope) {
    let value = min(max(Float(percent) / 100.0, 0.0), 1.0)
    DispatchQueue.main.async {
      os_log("Scheduled brightness: applying %d percent (scope %d) to displays.", type: .info, percent, scope.rawValue)
      for display in DisplayManager.shared.getAllDisplays() {
        let isBuiltIn = CGDisplayIsBuiltin(display.identifier) != 0
        switch scope {
        case .all:
          break
        case .externalOnly:
          guard !isBuiltIn else { continue }
        case .builtInOnly:
          guard isBuiltIn else { continue }
        }
        _ = display.setSmoothBrightness(value)
      }
      // Keep the menu bar sliders in sync (live update if the menu is open).
      menu?.updateMenus(dontClose: true)
    }
  }

  // MARK: Persistence

  static func loadRules() -> [BrightnessSchedule] {
    guard let data = prefs.data(forKey: PrefKey.scheduledBrightnessRules.rawValue) else {
      return []
    }
    let rules = try? JSONDecoder().decode([BrightnessSchedule].self, from: data)
    return rules ?? []
  }

  static func saveRules(_ rules: [BrightnessSchedule]) {
    if let data = try? JSONEncoder().encode(rules) {
      prefs.set(data, forKey: PrefKey.scheduledBrightnessRules.rawValue)
    }
  }
}

// MARK: - Preferences pane

final class ScheduledBrightnessPrefsViewController: NSViewController, SettingsPane {
  /// Preferred pane size: matches the 730pt width of the storyboard panes.
  /// The size constraints use a slightly-lower-than-required priority so the
  /// Settings framework's pin-to-window constraints always win and the window
  /// never ends up fighting the pane for size.
  private static let paneWidth: CGFloat = 730
  private static let paneHeight: CGFloat = 480

  let paneIdentifier: Settings.PaneIdentifier = .scheduledBrightness
  let paneTitle: String = ScheduledBrightnessPrefsViewController.isChineseUI ? "定时亮度" : "Scheduled Brightness"

  var toolbarItemIcon: NSImage {
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      return NSImage(systemSymbolName: "deskclock", accessibilityDescription: "Scheduled brightness")!
    } else {
      return NSImage(named: NSImage.cautionName)!
    }
  }

  private var scrollView: NSScrollView!
  private var docView: NSView!
  private var contentStackView: NSStackView!
  private var rulesStackView: NSStackView!
  private var percentLabels: [String: NSTextField] = [:]

  static var isChineseUI: Bool {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true
  }

  private func s(_ chinese: String, _ english: String) -> String {
    ScheduledBrightnessPrefsViewController.isChineseUI ? chinese : english
  }

  override func loadView() {
    let headerText = NSTextField(labelWithString: self.s("在设定的时间自动将所选屏幕亮度调整到指定值。", "Automatically set the chosen displays to the chosen brightness at the chosen times."))
    headerText.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    headerText.textColor = .secondaryLabelColor
    headerText.lineBreakMode = .byWordWrapping
    headerText.alignment = .center
    headerText.preferredMaxLayoutWidth = ScheduledBrightnessPrefsViewController.paneWidth - 80

    let addButton = self.makeAddButton()

    let noteText = NSTextField(labelWithString: self.s("规则较多时此区域内部滚动，窗口大小保持不变。", "The list scrolls inside the pane when it grows; the window size stays fixed."))
    noteText.font = NSFont.systemFont(ofSize: 11)
    noteText.textColor = .tertiaryLabelColor
    noteText.alignment = .center

    self.rulesStackView = NSStackView(views: [])
    self.rulesStackView.orientation = .vertical
    self.rulesStackView.alignment = .width
    self.rulesStackView.spacing = 0

    // Grouped card container in System Settings style.
    let cardView = NSView()
    cardView.wantsLayer = true
    cardView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    cardView.layer?.borderColor = NSColor.separatorColor.cgColor
    cardView.layer?.borderWidth = 1
    cardView.layer?.cornerRadius = 10
    cardView.layer?.masksToBounds = true
    cardView.widthAnchor.constraint(equalToConstant: 600).isActive = true
    cardView.addSubview(self.rulesStackView)
    self.rulesStackView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      self.rulesStackView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 4),
      self.rulesStackView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -4),
      self.rulesStackView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
      self.rulesStackView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
    ])

    self.contentStackView = NSStackView(views: [headerText, cardView, addButton, noteText])
    self.contentStackView.orientation = .vertical
    self.contentStackView.alignment = .centerX
    self.contentStackView.spacing = 14

    // Frame-based document view hosting an Auto Layout stack: the document
    // height is measured from the stack's fitting size, which keeps the
    // content top-anchored (no dead space) and scrolling reliable.
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    let docView = NSView()
    scrollView.documentView = docView
    self.scrollView = scrollView
    self.docView = docView
    docView.addSubview(self.contentStackView)
    self.contentStackView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      self.contentStackView.topAnchor.constraint(equalTo: docView.topAnchor, constant: 18),
      self.contentStackView.centerXAnchor.constraint(equalTo: docView.centerXAnchor),
      self.contentStackView.widthAnchor.constraint(lessThanOrEqualTo: docView.widthAnchor, constant: -48),
    ])

    let containerView = NSView()
    containerView.addSubview(scrollView)
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    let widthConstraint = containerView.widthAnchor.constraint(equalToConstant: ScheduledBrightnessPrefsViewController.paneWidth)
    let heightConstraint = containerView.heightAnchor.constraint(equalToConstant: ScheduledBrightnessPrefsViewController.paneHeight)
    widthConstraint.priority = NSLayoutConstraint.Priority(999)
    heightConstraint.priority = NSLayoutConstraint.Priority(999)
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
      scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
      scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
      scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -16),
      widthConstraint,
      heightConstraint,
    ])
    self.view = containerView
    self.reloadRules()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    self.updateDocumentFrame()
  }

  private func updateDocumentFrame() {
    guard let scrollView = self.scrollView, let docView = self.docView else {
      return
    }
    let clipBounds = scrollView.contentView.bounds
    let fittingHeight = self.contentStackView.fittingSize.height
    let newHeight = max(fittingHeight + 16, clipBounds.height)
    if abs(docView.frame.height - newHeight) > 0.5 || abs(docView.frame.width - clipBounds.width) > 0.5 {
      docView.frame = NSRect(x: 0, y: 0, width: clipBounds.width, height: newHeight)
    }
  }

  // MARK: Rule rows

  private func reloadRules() {
    self.percentLabels.removeAll()
    self.rulesStackView.views.forEach { self.rulesStackView.removeView($0) }
    let rules = ScheduledBrightnessManager.loadRules()
    if rules.isEmpty {
      let emptyLabel = NSTextField(labelWithString: self.s("暂无定时规则，点击下方按钮添加。", "No schedules yet. Click the button below to add one."))
      emptyLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
      emptyLabel.textColor = .secondaryLabelColor
      let emptyWrapper = NSView()
      emptyWrapper.addSubview(emptyLabel)
      emptyLabel.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        emptyLabel.centerXAnchor.constraint(equalTo: emptyWrapper.centerXAnchor),
        emptyLabel.topAnchor.constraint(equalTo: emptyWrapper.topAnchor, constant: 14),
        emptyLabel.bottomAnchor.constraint(equalTo: emptyWrapper.bottomAnchor, constant: -14),
      ])
      self.rulesStackView.addArrangedSubview(emptyWrapper)
    } else {
      for (index, rule) in rules.enumerated() {
        if index > 0 {
          self.rulesStackView.addArrangedSubview(self.makeSeparator())
        }
        self.rulesStackView.addArrangedSubview(self.makeRow(rule: rule))
      }
    }
    DispatchQueue.main.async { [weak self] in
      self?.updateDocumentFrame()
    }
  }

  private func makeSeparator() -> NSView {
    let separator = NSView()
    separator.translatesAutoresizingMaskIntoConstraints = false
    separator.wantsLayer = true
    separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
    separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
    separator.widthAnchor.constraint(equalTo: self.rulesStackView.widthAnchor, constant: -28).isActive = true
    return separator
  }

  private func makeAddButton() -> NSButton {
    let title = self.s("＋ 添加定时", "＋ Add schedule")
    let addButton = NSButton(title: title, target: self, action: #selector(self.addRule(_:)))
    addButton.isBordered = false
    addButton.wantsLayer = true
    addButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    addButton.layer?.cornerRadius = 7
    addButton.attributedTitle = NSAttributedString(string: title, attributes: [
      .foregroundColor: NSColor.white,
      .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    ])
    addButton.widthAnchor.constraint(equalToConstant: 110).isActive = true
    addButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
    return addButton
  }

  private func makeRow(rule: BrightnessSchedule) -> NSView {
    let enableSwitch = NSSwitch()
    enableSwitch.state = rule.enabled ? .on : .off
    enableSwitch.target = self
    enableSwitch.action = #selector(self.ruleToggled(_:))
    enableSwitch.toolTip = self.s("启用此定时", "Enable this schedule")
    enableSwitch.identifier = NSUserInterfaceItemIdentifier(rule.id)

    let datePicker = NSDatePicker()
    if #available(macOS 10.15.4, *) {
      datePicker.datePickerStyle = .textField
    } else {
      datePicker.datePickerStyle = .clockAndCalendar
    }
    datePicker.datePickerElements = .hourMinute
    datePicker.datePickerMode = .single
    datePicker.timeZone = TimeZone.current
    var components = DateComponents()
    components.hour = rule.hour
    components.minute = rule.minute
    datePicker.dateValue = Calendar.current.date(from: components) ?? Date()
    datePicker.target = self
    datePicker.action = #selector(self.ruleTimeChanged(_:))
    datePicker.identifier = NSUserInterfaceItemIdentifier(rule.id)

    let scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    scopePopup.addItems(withTitles: [
      self.s("所有屏幕", "All displays"),
      self.s("仅外接", "External only"),
      self.s("仅内建", "Built-in only"),
    ])
    scopePopup.selectItem(at: rule.scope.rawValue)
    scopePopup.target = self
    scopePopup.action = #selector(self.ruleScopeChanged(_:))
    scopePopup.identifier = NSUserInterfaceItemIdentifier(rule.id)

    let slider = NSSlider(value: Double(rule.brightness), minValue: 0, maxValue: 100, target: self, action: #selector(self.ruleBrightnessChanged(_:)))
    slider.isContinuous = true
    slider.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    slider.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    slider.identifier = NSUserInterfaceItemIdentifier(rule.id)

    let percentLabel = NSTextField(labelWithString: "\(rule.brightness)%")
    percentLabel.alignment = .right
    self.percentLabels[rule.id] = percentLabel

    let deleteButton: NSButton
    if #available(macOS 11.0, *) {
      deleteButton = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: self.s("删除", "Delete"))!, target: self, action: #selector(self.ruleDeleted(_:)))
      deleteButton.isBordered = false
      deleteButton.contentTintColor = .secondaryLabelColor
    } else {
      deleteButton = NSButton(title: self.s("删除", "Delete"), target: self, action: #selector(self.ruleDeleted(_:)))
      deleteButton.bezelStyle = .rounded
    }
    deleteButton.identifier = NSUserInterfaceItemIdentifier(rule.id)

    let row = NSStackView(views: [enableSwitch, datePicker, scopePopup, slider, percentLabel, deleteButton])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.distribution = .fill
    row.spacing = 10
    row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
    return row
  }

  private func rule(withID id: String) -> Int? {
    ScheduledBrightnessManager.loadRules().firstIndex { $0.id == id }
  }

  private func controlID(_ sender: NSControl?) -> String? {
    sender?.identifier?.rawValue
  }

  // MARK: Actions

  @objc private func addRule(_ sender: Any?) {
    var rules = ScheduledBrightnessManager.loadRules()
    rules.append(BrightnessSchedule(hour: 22, minute: 0, brightness: 30))
    ScheduledBrightnessManager.saveRules(rules)
    self.reloadRules()
  }

  @objc private func ruleDeleted(_ sender: NSButton) {
    guard let id = self.controlID(sender), let index = self.rule(withID: id) else {
      return
    }
    var rules = ScheduledBrightnessManager.loadRules()
    rules.remove(at: index)
    ScheduledBrightnessManager.saveRules(rules)
    self.reloadRules()
  }

  @objc private func ruleToggled(_ sender: NSSwitch) {
    guard let id = self.controlID(sender), let index = self.rule(withID: id) else {
      return
    }
    var rules = ScheduledBrightnessManager.loadRules()
    rules[index].enabled = sender.state == .on
    ScheduledBrightnessManager.saveRules(rules)
  }

  @objc private func ruleTimeChanged(_ sender: NSDatePicker) {
    guard let id = self.controlID(sender), let index = self.rule(withID: id) else {
      return
    }
    var rules = ScheduledBrightnessManager.loadRules()
    let components = Calendar.current.dateComponents([.hour, .minute], from: sender.dateValue)
    rules[index].hour = components.hour ?? 0
    rules[index].minute = components.minute ?? 0
    ScheduledBrightnessManager.saveRules(rules)
  }

  @objc private func ruleScopeChanged(_ sender: NSPopUpButton) {
    guard let id = self.controlID(sender), let index = self.rule(withID: id), let scope = DisplayScope(rawValue: sender.indexOfSelectedItem) else {
      return
    }
    var rules = ScheduledBrightnessManager.loadRules()
    rules[index].scope = scope
    ScheduledBrightnessManager.saveRules(rules)
  }

  @objc private func ruleBrightnessChanged(_ sender: NSSlider) {
    guard let id = self.controlID(sender), let index = self.rule(withID: id) else {
      return
    }
    var rules = ScheduledBrightnessManager.loadRules()
    let value = Int(sender.doubleValue.rounded())
    rules[index].brightness = value
    ScheduledBrightnessManager.saveRules(rules)
    self.percentLabels[id]?.stringValue = "\(value)%"
  }
}
