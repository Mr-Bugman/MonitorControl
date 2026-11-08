//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  Scheduled brightness feature: timed rules that set all displays to a chosen brightness.

import Cocoa
import os.log
import Settings

// MARK: - Model

struct BrightnessSchedule: Codable, Equatable {
  var id: String = UUID().uuidString
  var enabled: Bool = true
  var hour: Int
  var minute: Int
  /// Target brightness, 0-100 (%)
  var brightness: Int
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
        self.applyBrightness(rule.brightness)
      } else {
        self.firedKeys.remove(fireKey)
      }
    }
    if self.firedKeys.count > 100 {
      self.firedKeys.removeAll()
    }
  }

  func applyBrightness(_ percent: Int) {
    let value = min(max(Float(percent) / 100.0, 0.0), 1.0)
    DispatchQueue.main.async {
      os_log("Scheduled brightness: applying %d percent to all affected displays.", type: .info, percent)
      if let displays = DisplayManager.shared.getAffectedDisplays(isBrightness: true) {
        for display in displays {
          _ = display.setSmoothBrightness(value)
        }
      }
    }
  }

  // MARK: Persistence

  static func loadRules() -> [BrightnessSchedule] {
    guard let data = prefs.data(forKey: PrefKey.scheduledBrightnessRules.rawValue) else {
      return []
    }
    return (try? JSONDecoder().decode([BrightnessSchedule].self, from: data)) ?? []
  }

  static func saveRules(_ rules: [BrightnessSchedule]) {
    if let data = try? JSONEncoder().encode(rules) {
      prefs.set(data, forKey: PrefKey.scheduledBrightnessRules.rawValue)
    }
  }
}

// MARK: - Preferences pane

final class ScheduledBrightnessPrefsViewController: NSViewController, SettingsPane {
  let paneIdentifier: Settings.PaneIdentifier = .scheduledBrightness
  let paneTitle: String = ScheduledBrightnessPrefsViewController.isChineseUI ? "定时亮度" : "Scheduled Brightness"

  var toolbarItemIcon: NSImage {
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      return NSImage(systemSymbolName: "deskclock", accessibilityDescription: "Scheduled brightness")!
    } else {
      return NSImage(named: NSImage.cautionName)!
    }
  }

  private var rulesStackView: NSStackView!
  private var percentLabels: [String: NSTextField] = [:]

  static var isChineseUI: Bool {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true
  }

  private func s(_ chinese: String, _ english: String) -> String {
    ScheduledBrightnessPrefsViewController.isChineseUI ? chinese : english
  }

  override func loadView() {
    let headerText = NSTextField(labelWithString: self.s("在设定的时间自动将所有屏幕亮度调整到指定值。", "Automatically set all displays to the chosen brightness at the chosen times."))
    headerText.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    headerText.textColor = .secondaryLabelColor
    headerText.lineBreakMode = .byWordWrapping
    headerText.preferredMaxLayoutWidth = 420

    let addButton = NSButton(title: self.s("＋ 添加定时", "＋ Add schedule"), target: self, action: #selector(self.addRule(_:)))
    addButton.bezelStyle = .rounded

    self.rulesStackView = NSStackView(views: [])
    self.rulesStackView.orientation = .vertical
    self.rulesStackView.alignment = .leading
    self.rulesStackView.spacing = 10

    let contentStackView = NSStackView(views: [headerText, self.rulesStackView, addButton])
    contentStackView.orientation = .vertical
    contentStackView.alignment = .leading
    contentStackView.spacing = 12

    // Plain container with the stack pinned inside. The Settings framework sizes
    // the window from the pane view's fittingSize, so the container must derive
    // its size from content constraints (a scroll view would collapse to zero).
    let containerView = NSView()
    containerView.addSubview(contentStackView)
    contentStackView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      contentStackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
      contentStackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
      contentStackView.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor, constant: -16),
      contentStackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -16),
    ])
    self.view = containerView
    self.reloadRules()
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
      self.rulesStackView.addArrangedSubview(emptyLabel)
    } else {
      for rule in rules {
        self.rulesStackView.addArrangedSubview(self.makeRow(rule: rule))
      }
    }
    self.syncWindowSize()
  }

  /// Keep the prefs window size in sync when rules are added or removed.
  private func syncWindowSize() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, let window = self.view.window else {
        return
      }
      let contentSize = self.view.fittingSize
      guard contentSize.width > 1, contentSize.height > 1 else {
        return
      }
      let newFrame = window.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize))
      var frame = window.frame
      frame.origin.y += window.frame.height - newFrame.height
      frame.size = NSSize(width: max(frame.width, newFrame.width), height: newFrame.height)
      window.setFrame(frame, display: true, animate: true)
    }
  }

  private func makeRow(rule: BrightnessSchedule) -> NSView {
    let enableSwitch = NSSwitch()
    enableSwitch.state = rule.enabled ? .on : .off
    enableSwitch.target = self
    enableSwitch.action = #selector(self.ruleToggled(_:))
    enableSwitch.toolTip = self.s("启用此定时", "Enable this schedule")
    enableSwitch.identifier = NSUserInterfaceItemIdentifier(rule.id)

    let datePicker = NSDatePicker()
    datePicker.datePickerStyle = .clockAndCalendar
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

    let slider = NSSlider(value: Double(rule.brightness), minValue: 0, maxValue: 100, target: self, action: #selector(self.ruleBrightnessChanged(_:)))
    slider.isContinuous = true
    slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
    slider.identifier = NSUserInterfaceItemIdentifier(rule.id)

    let percentLabel = NSTextField(labelWithString: "\(rule.brightness)%")
    self.percentLabels[rule.id] = percentLabel

    let deleteButton = NSButton(title: self.s("删除", "Delete"), target: self, action: #selector(self.ruleDeleted(_:)))
    deleteButton.bezelStyle = .rounded
    deleteButton.identifier = NSUserInterfaceItemIdentifier(rule.id)

    let row = NSStackView(views: [enableSwitch, datePicker, slider, percentLabel, deleteButton])
    row.orientation = .horizontal
    row.spacing = 8
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
    let defaultComponents = DateComponents(hour: 22, minute: 0)
    let hour = Calendar.current.date(from: defaultComponents).map { Calendar.current.component(.hour, from: $0) } ?? 22
    rules.append(BrightnessSchedule(hour: hour, minute: 0, brightness: 30))
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
