// «Запись звонков» — кнопка в строке меню: клик начинает или останавливает запись (~/.call-recorder/call-recorder.sh on/off),
// иконка показывает состояние: ◯ — запись не идёт, красный ● с таймером — идёт запись.
// Правый клик (или Control-клик) открывает меню.
import AppKit
import ServiceManagement

let home = FileManager.default.homeDirectoryForCurrentUser.path
let script = home + "/.call-recorder/call-recorder.sh"
let recDir = home + "/Movies/Записи звонков"
let currentDir = home + "/.call-recorder/current"   // WAV текущей записи
let logPath = home + "/.call-recorder/logs/calltap.log"
let settingsPath = home + "/.call-recorder/settings"   // строки вида split=no; их же читает call-recorder.sh

/// Сохранять ли голоса отдельными файлами; выключается строкой split=no, по умолчанию включено.
func splitEnabled() -> Bool {
    let lines = ((try? String(contentsOfFile: settingsPath, encoding: .utf8)) ?? "").split(separator: "\n")
    return lines.last { $0.hasPrefix("split=") } != "split=no"
}

func setSplitEnabled(_ on: Bool) {
    var lines = ((try? String(contentsOfFile: settingsPath, encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("split=") }
    lines.append("split=" + (on ? "yes" : "no"))
    try? (lines.joined(separator: "\n") + "\n").write(toFile: settingsPath, atomically: true, encoding: .utf8)
}

func runningProcessNames() -> Set<String> {
    let n = proc_listallpids(nil, 0)
    var pids = [pid_t](repeating: 0, count: Int(n) + 64)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    var names = Set<String>()
    var buf = [CChar](repeating: 0, count: 4096)
    for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            names.insert((String(cString: buf) as NSString).lastPathComponent)
        }
    }
    return names
}

func creationDate(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
}

func newestFile(in dir: String, ext: String) -> URL? {
    let urls = (try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
    return urls.filter { $0.pathExtension == ext }.max { creationDate($0) < creationDate($1) }
}

func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }

/// Последняя запись: папка звонка или .m4a в корне (так сохранялись записи до разделения на три файла).
func latestRecording() -> URL? {
    let urls = (try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: recDir), includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
    return urls.filter { $0.lastPathComponent.hasPrefix("Звонок") && (isDirectory($0) || $0.pathExtension == "m4a") }
        .max { creationDate($0) < creationDate($1) }
}

/// CallTap не дождался звука от AirPods и пишет встроенный микрофон Mac.
func micFallback() -> Bool {
    ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "").contains("пишу встроенный микрофон")
}

/// Микрофон молчит: CallTap пишет уровни через 3 с и дальше раз в 10 с; первые секунды AirPods ещё
/// переключаются в режим гарнитуры, поэтому тревожимся, только если молчит и последняя строка после первой.
func micSilent() -> Bool {
    guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return false }
    let levels = text.split(separator: "\n").filter { $0.contains("уровень") }
    return levels.count >= 2 && levels.last?.contains("микрофон   -inf") == true
}

func symbol(_ name: String, red: Bool = false) -> NSImage? {
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: "Запись звонков") else { return nil }
    if red, let colored = img.withSymbolConfiguration(.init(paletteColors: [.systemRed])) {
        colored.isTemplate = false
        return colored
    }
    img.isTemplate = true
    return img
}

// MARK: - Окно «Детали»

/// Уровни текущей записи прямо из её WAV: CallTap дописывает файл порциями примерно каждые 0,2 с
/// (16 бит, канал 1 — собеседник, канал 2 — микрофон), так что шкалам не нужна связь с CallTap.
final class WavLevelReader {
    private var url: URL?
    private var dataStart: UInt64 = 0
    private var lastSize: UInt64 = 0

    /// Пики каналов (0…1) по данным, дописанным с прошлого вызова (не больше 0,1 с); nil — новых данных нет.
    func read() -> (far: Float, mic: Float)? {
        guard let wav = newestFile(in: currentDir, ext: "wav") else { url = nil; return nil }
        if wav != url { url = wav; dataStart = 0; lastSize = 0 }
        guard let h = try? FileHandle(forReadingFrom: wav) else { return nil }
        defer { try? h.close() }
        if dataStart == 0 { dataStart = findDataStart(h) ?? 0 }
        guard dataStart > 0, let size = try? h.seekToEnd(), size > max(lastSize, dataStart) else { return nil }
        var from = max(lastSize, dataStart, size > 19_200 ? size - 19_200 : 0)
        from = dataStart + (from - dataStart) / 4 * 4
        lastSize = size
        guard (try? h.seek(toOffset: from)) != nil, let data = try? h.read(upToCount: Int(size - from)), data.count >= 4 else { return nil }
        var far: Int32 = 0, mic: Int32 = 0
        data.withUnsafeBytes { raw in
            var i = 0
            while i + 4 <= raw.count {
                far = max(far, abs(Int32(raw.loadUnaligned(fromByteOffset: i, as: Int16.self))))
                mic = max(mic, abs(Int32(raw.loadUnaligned(fromByteOffset: i + 2, as: Int16.self))))
                i += 4
            }
        }
        return (Float(far) / 32768, Float(mic) / 32768)
    }

    /// Начало звука в WAV: после заголовка RIFF идут блоки (fmt, FLLR, …), нужен блок data.
    private func findDataStart(_ h: FileHandle) -> UInt64? {
        guard (try? h.seek(toOffset: 0)) != nil, let head = try? h.read(upToCount: 65_536),
              head.count > 12, head.prefix(4) == Data("RIFF".utf8) else { return nil }
        let bytes = [UInt8](head)
        var off = 12
        while off + 8 <= bytes.count {
            let id = String(bytes: bytes[off..<off + 4], encoding: .ascii)
            if id == "data" { return UInt64(off + 8) }
            let len = Int(bytes[off + 4]) | Int(bytes[off + 5]) << 8 | Int(bytes[off + 6]) << 16 | Int(bytes[off + 7]) << 24
            off += 8 + len + (len & 1)
        }
        return nil
    }
}

/// Горизонтальная шкала от −60 до 0 дБ: зелёная, с −12 дБ жёлтая, с −3 дБ красная; риска — пик за последние 1,5 с.
final class LevelMeterView: NSView {
    var level: Float = -60 { didSet { needsDisplay = true } }
    var peak: Float = -60 { didSet { needsDisplay = true } }

    private func x(_ db: Float) -> CGFloat { bounds.width * CGFloat((max(-60, min(0, db)) + 60) / 60) }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        NSColor.quaternaryLabelColor.setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let zones: [(Float, Float, NSColor)] = [(-60, -12, .systemGreen), (-12, -3, .systemYellow), (-3, 0, .systemRed)]
        for (from, to, color) in zones {
            let a = x(from), b = min(x(to), x(level))
            if b > a { color.setFill(); NSRect(x: a, y: 0, width: b - a, height: bounds.height).fill() }
        }
        if peak > -60 {
            NSColor.labelColor.withAlphaComponent(0.7).setFill()
            NSRect(x: max(0, x(peak) - 1), y: 0, width: 2, height: bounds.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Небольшое окно поверх остальных: уровни собеседника и микрофона в реальном времени,
/// кнопка записи и настройка «сохранять голоса отдельно».
final class DetailsWindow: NSObject, NSWindowDelegate {
    private unowned let app: AppDelegate
    private let panel: NSPanel
    private let status = NSTextField(labelWithString: "")
    private let farMeter = LevelMeterView(), micMeter = LevelMeterView()
    private let farValue = NSTextField(labelWithString: ""), micValue = NSTextField(labelWithString: "")
    private let warning = NSTextField(wrappingLabelWithString: "")
    private let splitBox = NSButton(checkboxWithTitle: "Сохранять голоса отдельно: «я» и «собеседник»", target: nil, action: nil)
    private let recordButton = NSButton(title: "", target: nil, action: nil)
    private let reader = WavLevelReader()
    private var timer: Timer?
    private var farHold: (db: Float, at: Date) = (-60, .distantPast)
    private var micHold: (db: Float, at: Date) = (-60, .distantPast)
    private var lastData = Date.distantPast

    init(app: AppDelegate) {
        self.app = app
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        panel.title = "Запись звонков"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        status.font = .boldSystemFont(ofSize: 13)
        warning.textColor = .systemOrange
        warning.preferredMaxLayoutWidth = 388
        splitBox.target = self
        splitBox.action = #selector(splitChanged)
        splitBox.toolTip = "Выключите, чтобы сохранять один файл с обоими голосами. Действует при сохранении записи."
        recordButton.target = self
        recordButton.action = #selector(recordPressed)
        recordButton.bezelStyle = .rounded
        recordButton.keyEquivalent = "\r"
        let folderButton = NSButton(title: "Открыть папку", target: app, action: #selector(AppDelegate.openFolder))
        folderButton.bezelStyle = .rounded
        let separator = NSBox()
        separator.boxType = .separator

        let stack = NSStackView(views: [status, meterRow("Собеседник", farMeter, farValue), meterRow("Я (микрофон)", micMeter, micValue),
                                        warning, separator, splitBox, NSStackView(views: [recordButton, folderButton])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        panel.contentView = stack
    }

    private func meterRow(_ title: String, _ meter: LevelMeterView, _ value: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 96).isActive = true
        meter.widthAnchor.constraint(equalToConstant: 200).isActive = true
        meter.heightAnchor.constraint(equalToConstant: 10).isActive = true
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let row = NSStackView(views: [label, meter, value])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    func show() {
        tick()
        fitToContent()
        if !panel.isVisible { panel.center() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let fresh = app.recording ? reader.read() : nil
        if fresh != nil { lastData = Date() }
        update(farMeter, farValue, &farHold, fresh.map { $0.far })
        update(micMeter, micValue, &micHold, fresh.map { $0.mic })

        if app.busy {
            status.stringValue = "Подождите…"
            status.textColor = .labelColor
        } else if app.recording {
            status.stringValue = "● Идёт запись · " + app.elapsed()
            status.textColor = .systemRed
        } else {
            status.stringValue = "Запись не идёт"
            status.textColor = .labelColor
        }
        // Файл записи не растёт — звук не поступает (CallTap в это время сам перезапускает захват).
        let started = app.recordingStart.map { Date().timeIntervalSince($0) > 6 } ?? false
        let text: String
        if app.recording && started && Date().timeIntervalSince(lastData) > 4 {
            text = "⚠︎ Звук не поступает — CallTap перезапускает захват. Если это не проходит, остановите и начните запись снова."
        } else if app.recording && micFallback() {
            text = "⚠︎ Микрофон AirPods не запустился — ваш голос записывается встроенным микрофоном Mac. Чтобы вернуть AirPods, остановите запись, положите наушники в кейс на 15 секунд и начните снова."
        } else if app.recording && micSilent() {
            text = "⚠︎ Микрофон молчит больше 10 секунд — ваш голос не пишется. Разрешите CallTap доступ к микрофону в Системных настройках."
        } else {
            text = ""
        }
        if warning.stringValue != text || warning.isHidden != text.isEmpty {
            warning.stringValue = text
            warning.isHidden = text.isEmpty
            fitToContent()
        }
        splitBox.state = splitEnabled() ? .on : .off
        recordButton.title = app.recording ? "Остановить и сохранить" : "Начать запись"
        recordButton.isEnabled = !app.busy
    }

    private func fitToContent() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(content.fittingSize)
    }

    /// Шкала падает на 30 дБ/с, если громкость снизилась или новых данных нет; риска пика держится 1,5 с.
    private func update(_ meter: LevelMeterView, _ value: NSTextField, _ hold: inout (db: Float, at: Date), _ peak: Float?) {
        var db = meter.level - 1.5
        if let peak, peak > 0 { db = max(db, 20 * log10(peak)) }
        db = max(-60, min(0, db))
        meter.level = db
        if db >= hold.db || Date().timeIntervalSince(hold.at) > 1.5 { hold = (db, Date()) }
        meter.peak = hold.db
        value.stringValue = db <= -59.5 ? "—" : String(format: "%.0f дБ", db)
    }

    @objc private func splitChanged() { setSplitEnabled(splitBox.state == .on) }
    @objc private func recordPressed() { app.toggle() }
}

// MARK: - Кнопка в строке меню

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let menu = NSMenu()
    lazy var details = DetailsWindow(app: self)
    var busy = false
    var recording = false
    var recordingStart: Date?
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Новые значки встают левее всех и на MacBook прячутся под «чёлку»; ставим кнопку рядом с батареей
        // (позиция — расстояние от правого края в пунктах). Если пользователь перетащит её с ⌘, macOS запомнит новое место.
        let positionKey = "NSStatusItem Preferred Position CallRecorder"
        if UserDefaults.standard.object(forKey: positionKey) == nil { UserDefaults.standard.set(290, forKey: positionKey) }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "CallRecorder"
        item.isVisible = true
        menu.autoenablesItems = false
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        // Где оказалась кнопка — для проверки, не попала ли она под «чёлку».
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            let frame = self?.item.button?.window?.frame ?? .zero
            let screen = NSScreen.main
            let notch = screen.map { "\($0.auxiliaryTopLeftArea ?? .zero) / \($0.auxiliaryTopRightArea ?? .zero)" } ?? "?"
            let line = "кнопка: \(frame), экран: \(screen?.frame ?? .zero), свободно слева/справа от чёлки: \(notch)\n"
            try? line.write(toFile: home + "/.call-recorder/logs/menubar.log", atomically: true, encoding: .utf8)
        }
    }

    @objc func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            buildMenu()
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            toggle()
        }
    }

    @objc func toggle() {
        guard !busy else { return }
        run(recording ? "off" : "on")
    }

    func run(_ arg: String) {
        busy = true
        refresh()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script, arg]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.terminationHandler = { proc in
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                if proc.terminationStatus != 0 { self.alert(out) }
            }
        }
        do { try p.run() } catch { busy = false; refresh(); alert("Не удалось запустить \(script): \(error.localizedDescription)") }
    }

    func refresh() {
        let rec = runningProcessNames().contains("CallTap")
        if rec && !recording { recordingStart = newestFile(in: currentDir, ext: "wav").map(creationDate) ?? Date() }
        if !rec { recordingStart = nil }
        recording = rec
        guard let b = item.button else { return }
        if busy {
            b.image = symbol("hourglass")
            b.title = ""
            b.toolTip = "Запись звонков: подождите…"
        } else if recording {
            let silent = micSilent()
            b.image = symbol("record.circle.fill", red: true)
            b.title = " " + elapsed() + (silent ? " ⚠︎" : "")
            b.toolTip = silent ? "Идёт запись, но микрофон молчит — разрешите CallTap доступ к микрофону (правый клик → меню)"
                               : "Идёт запись звонка. Клик — остановить и сохранить"
        } else {
            b.image = symbol("record.circle")
            b.title = ""
            b.toolTip = "Запись звонков. Клик — начать запись, правый клик — меню"
        }
    }

    func elapsed() -> String {
        let s = Int(Date().timeIntervalSince(recordingStart ?? Date()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    func buildMenu() {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?, enabled: Bool = true) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            mi.isEnabled = enabled && action != nil
            menu.addItem(mi)
            return mi
        }
        _ = add(recording ? "Идёт запись · \(elapsed())" : "Запись не идёт", nil)
        if recording && micSilent() {
            _ = add("⚠︎ Микрофон молчит — ваш голос не пишется", nil)
            _ = add("Открыть настройки доступа к микрофону…", #selector(openMicSettings))
        }
        menu.addItem(.separator())
        _ = add(recording ? "Остановить и сохранить" : "Начать запись", #selector(toggle), enabled: !busy)
        _ = add("Показать детали…", #selector(showDetails))
        menu.addItem(.separator())
        _ = add("Открыть папку с записями", #selector(openFolder))
        _ = add("Показать последнюю запись", #selector(revealLatest), enabled: latestRecording() != nil)
        menu.addItem(.separator())
        let split = add("Сохранять голоса отдельно (я / собеседник)", #selector(toggleSplit))
        split.state = splitEnabled() ? .on : .off
        let login = add("Запускать при входе в систему", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        _ = add("Убрать кнопку (запись не остановится)", #selector(quit))
    }

    @objc func showDetails() { details.show() }

    @objc func toggleSplit() { setSplitEnabled(!splitEnabled()) }

    @objc func openFolder() {
        try? FileManager.default.createDirectory(atPath: recDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: recDir))
    }

    @objc func revealLatest() {
        guard let last = latestRecording() else { return }
        if isDirectory(last) { NSWorkspace.shared.open(last) } else { NSWorkspace.shared.activateFileViewerSelecting([last]) }
    }

    @objc func openMicSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { alert("Не удалось изменить автозапуск: \(error.localizedDescription)") }
    }

    @objc func quit() { NSApp.terminate(nil) }

    func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "Запись звонков"
        a.informativeText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
