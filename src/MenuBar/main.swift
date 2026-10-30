// «Запись звонков» — кнопка в строке меню: левый клик сразу начинает запись (~/.call-recorder/call-recorder.sh on)
// и спрашивает имя клиента уже во время неё; правый клик и клик во время записи — меню с «Завершить запись»,
// настройками и, пока идёт запись, живыми шкалами уровней. Звонок с iPhone закончился — запись останавливается сама.
// Иконка показывает состояние: ◯ — запись не идёт, красный ◯ «Записать» — идёт звонок без записи,
// красный ● с таймером — идёт запись.
import AppKit
import CoreAudio
import ServiceManagement
import SystemConfiguration

let home = FileManager.default.homeDirectoryForCurrentUser.path
let script = home + "/.call-recorder/call-recorder.sh"
let recDir = home + "/Movies/Записи звонков"
let currentDir = home + "/.call-recorder/current"   // WAV текущей записи
let logPath = home + "/.call-recorder/logs/calltap.log"
let settingsPath = home + "/.call-recorder/settings"   // строки вида split=no, live=yes, server=…; их же читает call-recorder.sh
let tokenPath = home + "/.call-recorder/inbox-token"    // ключ сервера: только в этом файле (права 600), нигде не выводится
let liveStatusPath = home + "/.call-recorder/logs/live-status"
let uploadsDir = home + "/.call-recorder/uploads"
let errorLogPath = home + "/.call-recorder/logs/errors.jsonl"   // общий журнал ошибок (README, «Журнал ошибок»)
let sentPosPath = home + "/.call-recorder/logs/send-logs.pos"         // докуда журнал отправлен на сервер (call-recorder.sh send-logs)
let sendStatusPath = home + "/.call-recorder/logs/send-logs.status"   // итог последней отправки журнала: ok | retry | forbidden

let isoTime: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.timeZone = .current; return f }()

/// Событие в общий журнал ошибок — строка JSON, одним write() в файл с O_APPEND (как у call-recorder.sh и LiveStream).
func logEvent(_ level: String, _ event: String, _ message: String, session: String? = nil, details: [String: Any] = [:]) {
    var e: [String: Any] = ["id": UUID().uuidString.lowercased(), "time": isoTime.string(from: Date()), "level": level,
                            "source": "menu", "event": event, "message": message,
                            "host": (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName,
                            "version": ((try? String(contentsOfFile: home + "/.call-recorder/version", encoding: .utf8)) ?? "dev")
                                .trimmingCharacters(in: .whitespacesAndNewlines)]
    if let session, !session.isEmpty { e["session"] = session }
    if !details.isEmpty { e["details"] = details }
    guard var line = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
    line.append(0x0A)
    if let size = (try? FileManager.default.attributesOfItem(atPath: errorLogPath)[.size]) as? Int, size >= 2_000_000 {
        try? FileManager.default.removeItem(atPath: errorLogPath + ".1")
        try? FileManager.default.moveItem(atPath: errorLogPath, toPath: errorLogPath + ".1")
    }
    let fd = open(errorLogPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    line.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    close(fd)
}

/// Имя текущей (или последней) записи — оно же session в журнале и папка на сервере: current/.session (его пишет
/// call-recorder.sh при старте и после ввода имени клиента), у записей прошлых версий — из строки CallTap
/// «✅ запись идёт: … → /…/<имя записи>.wav (rate=…)».
func recordingName() -> String? {
    let saved = ((try? String(contentsOfFile: currentDir + "/.session", encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !saved.isEmpty { return saved }
    let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    guard let line = log.split(separator: "\n").last(where: { $0.contains("запись идёт") }) else { return nil }
    let wav = String(line).components(separatedBy: " → ").last?.components(separatedBy: ".wav (").first ?? ""
    return wav.isEmpty ? nil : (wav as NSString).lastPathComponent
}

/// CallTap пропал посреди записи? При обычной остановке он пишет в журнал «запись остановлена»; если запись
/// успела начаться, а этой строки нет — он упал или его убили. Пишем в журнал ошибок сразу и оставляем метку,
/// чтобы call-recorder.sh при сохранении не записал то же самое второй раз.
func noteIfCaptureDied() {
    let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    guard log.contains("запись идёт"), !log.contains("запись остановлена") else { return }
    let session = recordingName()
    logEvent("error", "calltap_died", "CallTap завершился сам посреди записи — запись оборвалась", session: session,
             details: ["log": log.split(separator: "\n").suffix(5).joined(separator: "\n")])
    FileManager.default.createFile(atPath: currentDir + "/.died-logged", contents: nil)
}

func setting(_ key: String) -> String? {
    let lines = ((try? String(contentsOfFile: settingsPath, encoding: .utf8)) ?? "").split(separator: "\n")
    return lines.last { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
}

func setSetting(_ key: String, _ value: String) {
    var lines = ((try? String(contentsOfFile: settingsPath, encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init).filter { !$0.hasPrefix(key + "=") }
    lines.append(key + "=" + value)
    try? (lines.joined(separator: "\n") + "\n").write(toFile: settingsPath, atomically: true, encoding: .utf8)
}

/// Сохранять ли голоса отдельными файлами; выключается строкой split=no, по умолчанию включено.
func splitEnabled() -> Bool { setting("split") != "no" }
func setSplitEnabled(_ on: Bool) { setSetting("split", on ? "yes" : "no") }

/// «Прямой эфир» — по умолчанию выключен.
func liveEnabled() -> Bool { setting("live") == "yes" }
func setLiveEnabled(_ on: Bool) { setSetting("live", on ? "yes" : "no") }

/// Останавливать запись, когда звонок закончился, — по умолчанию да (строка autostop=no выключает).
func autoStopEnabled() -> Bool { setting("autostop") != "no" }
func setAutoStopEnabled(_ on: Bool) { setSetting("autostop", on ? "yes" : "no") }

/// Идёт ли звонок с iPhone (или FaceTime): такие звонки на Mac обслуживает служба avconferenced, и пока звонок
/// идёт, она берёт звук с микрофона. Core Audio показывает это у каждого процесса (macOS 14+) — журналы читать не нужно.
final class CallMonitor {
    private var process = AudioObjectID(0)   // объект Core Audio службы avconferenced
    private var lastScan = Date.distantPast

    /// Раз в секунду — один запрос к Core Audio. Объект службы ищется заново, если его нет (не чаще раза в 5 с),
    /// если он перестал отвечать (служба перезапустилась) и на всякий случай раз в минуту.
    var callActive: Bool {
        let sinceScan = Date().timeIntervalSince(lastScan)
        if (process == 0 && sinceScan >= 5) || sinceScan >= 60 { scan() }
        guard process != 0 else { return false }
        if let running = runningInput() { return running }
        scan()
        return runningInput() ?? false
    }

    private func scan() {
        lastScan = Date()
        process = processes().first { string($0, kAudioProcessPropertyBundleID) == "com.apple.avconferenced" } ?? 0
    }

    private func runningInput() -> Bool? {
        guard process != 0 else { return nil }
        var a = address(kAudioProcessPropertyIsRunningInput)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &a, 0, nil, &size, &running) == noErr ? running != 0 : nil
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func processes() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var a = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        guard object != 0 else { return "" }
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr, let v = value else { return "" }
        return v.takeRetainedValue() as String
    }
}

func serverURL() -> String { setting("server") ?? "" }
func hasToken() -> Bool { ((try? FileManager.default.attributesOfItem(atPath: tokenPath)[.size]) as? Int ?? 0) > 0 }
func serverReady() -> Bool { !serverURL().isEmpty && hasToken() }

func saveToken(_ token: String) {
    FileManager.default.createFile(atPath: tokenPath, contents: Data((token + "\n").utf8), attributes: [.posixPermissions: 0o600])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenPath)
}

/// Состояние эфира для окна: LiveStream пишет в logs/live-status одно слово и обновляет файл после каждого
/// отправленного куска; если файл не обновлялся 3 с — связи нет.
func liveStateText(running: Bool) -> String {
    guard serverReady() else { return "не задан сервер или ключ" }
    guard running else { return "нет связи" }
    let state = ((try? String(contentsOfFile: liveStatusPath, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let modified = (try? FileManager.default.attributesOfItem(atPath: liveStatusPath)[.modificationDate]) as? Date ?? .distantPast
    switch state {
    case "wait": return "подключение…"
    case "on": return Date().timeIntervalSince(modified) < 3 ? "в эфире" : "нет связи"
    case "stopped": return "остановлен сервером"
    default: return "нет связи"
    }
}

/// Есть ли в журнале ошибок строки, ещё не отправленные на сервер: call-recorder.sh send-logs помнит
/// номер файла и позицию, докуда отправил.
func journalUnsent() -> Bool {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: errorLogPath),
          let size = attrs[.size] as? Int, size > 0 else { return false }
    let pos = ((try? String(contentsOfFile: sentPosPath, encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
    return pos != [attrs[.systemFileNumber] as? Int ?? -1, size]
}

/// Журнал не уходит на сервер: отказ в ключе — сразу (keyProblem), нет связи — если не получается дольше 10 минут.
func journalProblem() -> (text: String, keyProblem: Bool)? {
    guard serverReady() else { return nil }
    let lines = ((try? String(contentsOfFile: sendStatusPath, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    switch lines.first {
    case "forbidden": return ("⚠︎ Сервер не принял ключ — журнал ошибок не отправляется", true)
    case "retry" where Date().timeIntervalSince1970 - (Double(lines.count > 1 ? lines[1] : "") ?? 0) >= 600:
        return ("⚠︎ Журнал ошибок не отправлен — сервер недоступен, повтор раз в 5 минут", false)
    default: return nil
    }
}

/// call-recorder.sh с нужными аргументами; PATH — чтобы нашлись ffmpeg и прочее из Homebrew.
func scriptProcess(_ args: [String]) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script] + args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    p.environment = env
    return p
}

/// Последняя отправка записи на сервер: (состояние uploading/ok/failed, имя записи), если была за последний час.
func lastUpload() -> (state: String, name: String)? {
    let urls = (try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: uploadsDir), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
    func modified(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
    guard let last = urls.max(by: { modified($0) < modified($1) }) else { return nil }
    let state = ((try? String(contentsOf: last, encoding: .utf8)) ?? "").split(separator: "\n").first.map(String.init) ?? ""
    if state == "failed" { return (state, last.lastPathComponent) }   // неотправленное показываем, пока не дошлём
    return Date().timeIntervalSince(modified(last)) < 3600 ? (state, last.lastPathComponent) : nil
}

/// Короткие имена (до 16 знаков) всех процессов — одним системным вызовом. Раз в секунду это в 14 раз дешевле,
/// чем спрашивать путь к файлу каждого из ~800 процессов.
func runningProcessNames() -> Set<String> {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
    size = procs.count * MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return [] }
    return Set(procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { p in
        withUnsafeBytes(of: p.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    })
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

/// Последняя запись: папка звонка или .m4a в корне. Имена: «ГГГГ-ММ-ДД_ЧЧ-ММ_Имя» (раньше — «Звонок …»).
func latestRecording() -> URL? {
    let urls = (try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: recDir), includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
    let named = { (u: URL) in u.lastPathComponent.hasPrefix("Звонок") || u.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil }
    return urls.filter { named($0) && (isDirectory($0) || $0.pathExtension == "m4a") }
        .max { creationDate($0) < creationDate($1) }
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

/// Меню «Правка». У кнопки в строке меню нет своей строки меню, а ⌘V, ⌘C, ⌘X, ⌘A и ⌘Z в полях ввода
/// (имя клиента, «Сервер и ключ») macOS выполняет через пункты этого меню — без него в ответ только звук ошибки.
/// Самого меню не видно, работают только сочетания клавиш.
func installEditMenu() {
    let edit = NSMenu(title: "Правка")
    edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Выбрать все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let editItem = NSMenuItem()
    editItem.submenu = edit
    let main = NSMenu()
    main.addItem(NSMenuItem())   // первый пункт главного меню — меню приложения
    main.addItem(editItem)
    NSApp.mainMenu = main
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

/// Две шкалы — «Собеседник» и «Я (микрофон)» — со значениями в дБ; одни и те же для окна «Детали» и меню.
/// Шкала падает на 30 дБ/с, если громкость снизилась или новых данных нет; риска пика держится 1,5 с.
final class LevelsView: NSStackView {
    private let farMeter = LevelMeterView(), micMeter = LevelMeterView()
    private let farValue = NSTextField(labelWithString: "—"), micValue = NSTextField(labelWithString: "—")
    private var farHold: (db: Float, at: Date) = (-60, .distantPast)
    private var micHold: (db: Float, at: Date) = (-60, .distantPast)

    init(meterWidth: CGFloat) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        addArrangedSubview(row("Собеседник", farMeter, farValue, meterWidth))
        addArrangedSubview(row("Я (микрофон)", micMeter, micValue, meterWidth))
    }

    required init?(coder: NSCoder) { fatalError("не используется") }

    /// fresh — пики каналов (0…1), дописанные в WAV с прошлого раза; nil — новых данных нет.
    func update(_ fresh: (far: Float, mic: Float)?) {
        apply(farMeter, farValue, &farHold, fresh?.far)
        apply(micMeter, micValue, &micHold, fresh?.mic)
    }

    private func row(_ title: String, _ meter: LevelMeterView, _ value: NSTextField, _ meterWidth: CGFloat) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 96).isActive = true
        meter.widthAnchor.constraint(equalToConstant: meterWidth).isActive = true
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

    private func apply(_ meter: LevelMeterView, _ value: NSTextField, _ hold: inout (db: Float, at: Date), _ peak: Float?) {
        var db = meter.level - 1.5
        if let peak, peak > 0 { db = max(db, 20 * log10(peak)) }
        db = max(-60, min(0, db))
        meter.level = db
        if db >= hold.db || Date().timeIntervalSince(hold.at) > 1.5 { hold = (db, Date()) }
        meter.peak = hold.db
        value.stringValue = db <= -59.5 ? "—" : String(format: "%.0f дБ", db)
    }
}

/// Небольшое окно поверх остальных: уровни собеседника и микрофона в реальном времени,
/// кнопка записи и настройка «сохранять голоса отдельно». Уровни ему передаёт AppDelegate.
final class DetailsWindow: NSObject {
    private unowned let app: AppDelegate
    private let panel: NSPanel
    private let status = NSTextField(labelWithString: "")
    private let levels = LevelsView(meterWidth: 200)
    private let warning = NSTextField(wrappingLabelWithString: "")
    private let splitBox = NSButton(checkboxWithTitle: "Сохранять голоса отдельно: «я» и «собеседник»", target: nil, action: nil)
    private let liveBox = NSButton(checkboxWithTitle: "Прямой эфир: звук на сервер во время записи", target: nil, action: nil)
    private let recordButton = NSButton(title: "", target: nil, action: nil)

    var isVisible: Bool { panel.isVisible }

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

        status.font = .boldSystemFont(ofSize: 13)
        warning.textColor = .systemOrange
        warning.preferredMaxLayoutWidth = 388
        splitBox.target = self
        splitBox.action = #selector(splitChanged)
        splitBox.toolTip = "Выключите, чтобы сохранять один файл с обоими голосами. Действует при сохранении записи."
        liveBox.target = self
        liveBox.action = #selector(liveChanged)
        liveBox.toolTip = "Пока идёт запись, звук кусками уходит на сервер для подсказок по ходу разговора. Включается со следующей записи."
        recordButton.target = self
        recordButton.action = #selector(recordPressed)
        recordButton.bezelStyle = .rounded
        recordButton.keyEquivalent = "\r"
        recordButton.imagePosition = .imageLeading
        let folderButton = NSButton(title: "Открыть папку", target: app, action: #selector(AppDelegate.openFolder))
        folderButton.bezelStyle = .rounded
        let separator = NSBox()
        separator.boxType = .separator

        let stack = NSStackView(views: [status, levels, warning, separator, splitBox, liveBox, NSStackView(views: [recordButton, folderButton])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        panel.contentView = stack
    }

    func show() {
        tick(nil)
        fitToContent()
        if !panel.isVisible { panel.center() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        app.startLevelTicker()
    }

    func tick(_ fresh: (far: Float, mic: Float)?) {
        levels.update(fresh)
        status.stringValue = app.statusText()
        status.textColor = app.recording && !app.busy ? .systemRed : .labelColor
        let text: String
        if app.noAudio() {
            text = "⚠︎ Звук не поступает — CallTap перезапускает захват. Если это не проходит, завершите и начните запись снова."
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
        liveBox.state = liveEnabled() ? .on : .off
        let title = app.recording ? "Завершить запись" : "Начать запись"
        if recordButton.title != title {
            recordButton.title = title
            recordButton.image = symbol(app.recording ? "stop.circle.fill" : "record.circle.fill")
        }
        recordButton.isEnabled = !app.busy
    }

    private func fitToContent() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(content.fittingSize)
    }

    @objc private func splitChanged() { setSplitEnabled(splitBox.state == .on) }
    @objc private func liveChanged() { app.setLive(liveBox.state == .on) }
    @objc private func recordPressed() { app.toggle() }
}

// MARK: - Кнопка в строке меню

/// Клик по кнопке (левой или правой кнопкой мыши) открывает меню: «Начать запись» / «Завершить запись»,
/// а пока идёт запись — ещё и живые шкалы уровней.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    let menu = NSMenu()
    private var detailsWindow: DetailsWindow?
    var busy = false
    var recording = false
    var recordingStart: Date?
    var timer: Timer?

    // Уровни читаются из WAV одним таймером, пока открыто меню или окно «Детали».
    private let reader = WavLevelReader()
    private let menuLevels = LevelsView(meterWidth: 150)
    private var statusMenuItem: NSMenuItem?
    private(set) var liveRunning = false   // запущен ли LiveStream (обновляется раз в секунду в refresh)
    private var menuOpen = false
    private var levelTimer: Timer?
    private var lastLevelData = Date.distantPast
    private var logSender: Process?
    private var lastLogCheck = Date.distantPast

    // Звонок с iPhone: идёт ли он сейчас, был ли во время записи и когда закончился (для остановки записи).
    private let calls = CallMonitor()
    private(set) var callActive = false
    private var callSeenWhileRecording = false
    private var callEndedAt: Date?
    private var nameAlert: NSAlert?          // окно «Имя клиента», пока оно открыто
    private var shownButton = ""              // что сейчас на кнопке в строке меню (showButton)
    private var stopAfterNameAlert = false   // звонок закончился, пока окно было открыто

    /// Шкалы для меню: своё view в пункте меню с отступами, как у обычных пунктов.
    private lazy var menuLevelsItem: NSMenuItem = {
        let container = NSView()
        menuLevels.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(menuLevels)
        NSLayoutConstraint.activate([
            menuLevels.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            menuLevels.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            menuLevels.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            menuLevels.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        container.frame.size = container.fittingSize
        let mi = NSMenuItem()
        mi.view = container
        return mi
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        // Новые значки встают левее всех и на MacBook прячутся под «чёлку»; ставим кнопку рядом с батареей
        // (позиция — расстояние от правого края в пунктах). Если пользователь перетащит её с ⌘, macOS запомнит новое место.
        let positionKey = "NSStatusItem Preferred Position CallRecorder"
        if UserDefaults.standard.object(forKey: positionKey) == nil { UserDefaults.standard.set(290, forKey: positionKey) }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "CallRecorder"
        item.isVisible = true
        item.button?.imagePosition = .imageLeading
        menu.autoenablesItems = false
        menu.delegate = self
        // Левый клик — сразу запись; правый клик (и любой клик во время записи) — меню. Меню привязывается
        // к кнопке только на время показа, иначе macOS открывала бы его на любой клик.
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refresh()
        // Пока меню открыто, главный цикл работает в режиме отслеживания событий, и обычные таймеры
        // не срабатывают; в режиме .common время на кнопке идёт и при открытом меню.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Где оказалась кнопка — для проверки, не попала ли она под «чёлку».
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            let frame = self?.item.button?.window?.frame ?? .zero
            let screen = NSScreen.main
            let notch = screen.map { "\($0.auxiliaryTopLeftArea ?? .zero) / \($0.auxiliaryTopRightArea ?? .zero)" } ?? "?"
            let line = "кнопка: \(frame), экран: \(screen?.frame ?? .zero), свободно слева/справа от чёлки: \(notch)\n"
            try? line.write(toFile: home + "/.call-recorder/logs/menubar.log", atomically: true, encoding: .utf8)
        }
    }

    // MARK: Меню

    func menuNeedsUpdate(_ menu: NSMenu) { buildMenu() }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        startLevelTicker()
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false; item.menu = nil }

    @objc func statusClicked() {
        let event = NSApp.currentEvent
        let menuWanted = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if menuWanted || recording || busy { showMenu() } else { startRecording() }
    }

    func showMenu() {
        item.menu = menu
        item.button?.performClick(nil)
    }

    func startLevelTicker() {
        guard levelTimer == nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.levelTick() }
        RunLoop.main.add(t, forMode: .common)
        levelTimer = t
    }

    private func levelTick() {
        let detailsVisible = detailsWindow?.isVisible ?? false
        guard menuOpen || detailsVisible else { levelTimer?.invalidate(); levelTimer = nil; return }
        let fresh = recording ? reader.read() : nil
        if fresh != nil { lastLevelData = Date() }
        if menuOpen {
            menuLevels.update(fresh)
            statusMenuItem?.title = statusText()
        }
        if detailsVisible { detailsWindow?.tick(fresh) }
    }

    /// Файл записи не растёт больше 4 с (не считая первых 6 с) — звук не поступает.
    func noAudio() -> Bool {
        guard recording, let start = recordingStart, Date().timeIntervalSince(start) > 6 else { return false }
        return Date().timeIntervalSince(lastLevelData) > 4
    }

    func statusText() -> String {
        if busy { return "Подождите…" }
        guard recording else { return callActive ? "Идёт звонок — запись не идёт" : "Запись не идёт" }
        return "● Идёт запись · " + elapsed() + (liveEnabled() ? " · эфир: " + liveStateText(running: liveRunning) : "")
    }

    @objc func toggle() {
        guard !busy else { return }
        if recording { run(["off"]) } else { startRecording() }
    }

    /// Запись — сразу (call-recorder.sh on --name-later), имя клиента — уже во время неё.
    func startRecording() {
        guard !busy, !recording else { return }
        run(["on", "--name-later"]) { [weak self] ok in if ok { self?.askClientName() } }
    }

    /// Имя клиента, пока запись уже идёт: попадёт в название папки «ГГГГ-ММ-ДД_ЧЧ-ММ_Имя» и в карточку на сервере
    /// (call-recorder.sh name переименует запись и включит «Прямой эфир»). Если звонок закончится, пока окно открыто,
    /// оно закроется само, набранное имя всё равно достанется записи, и запись сохранится.
    func askClientName() {
        let a = NSAlert()
        a.messageText = "Запись идёт. Имя клиента?"
        a.informativeText = "Как в карточке или в телефоне. Можно оставить пустым — клиента выберете потом на сервере."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Например: Эрик Эглиенс"
        a.accessoryView = field
        a.addButton(withTitle: "Готово")
        a.addButton(withTitle: "Без имени")
        a.window.initialFirstResponder = field
        nameAlert = a
        NSApp.activate(ignoringOtherApps: true)
        let response = a.runModal()
        nameAlert = nil
        let name = response == .alertSecondButtonReturn ? "" : field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if stopAfterNameAlert {
            stopAfterNameAlert = false
            run(["name", name, "--no-live"]) { [weak self] _ in self?.autoStop() }
        } else {
            run(["name", name] + (recording ? [] : ["--no-live"]))   // CallTap успел завершиться — имя всё равно файлу
        }
    }

    /// Звонок закончился — сохранить запись, как по «Завершить запись».
    func autoStop() {
        callSeenWhileRecording = false
        callEndedAt = nil
        guard recording else { return }
        logEvent("info", "auto_stop", "Звонок закончился — запись остановлена сама", session: recordingName())
        run(["off"])
    }

    func setLive(_ on: Bool) {
        setLiveEnabled(on)
        if on && !serverReady() { showServerSettings() }
    }

    /// Адрес сервера и ключ: ключ вводится в скрытое поле и сохраняется в файл с правами 600.
    @objc func showServerSettings() {
        let a = NSAlert()
        a.messageText = "Сервер и ключ"
        a.informativeText = "Куда отправлять записи и прямой эфир. Ключ — INBOX_TOKEN из настроек сервера."
        let url = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        url.placeholderString = "https://crm.example.com"
        url.stringValue = serverURL()
        let token = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        token.placeholderString = hasToken() ? "ключ сохранён — оставьте пустым, чтобы не менять" : "вставьте ключ"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        box.addSubview(url)
        box.addSubview(token)
        a.accessoryView = box
        a.addButton(withTitle: "Сохранить")
        a.addButton(withTitle: "Отмена")
        a.window.initialFirstResponder = url
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let address = url.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if address.hasPrefix("https://") || address.hasPrefix("http://") { setSetting("server", address) }
        else if !address.isEmpty { alert("Адрес сервера должен начинаться с https://") }
        let secret = token.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty { saveToken(secret) }
        lastLogCheck = .distantPast   // журнал — сразу с новым ключом или адресом
    }

    /// Раз в 30 с: если в журнале ошибок есть новые строки — call-recorder.sh send-logs --auto в фоне.
    /// Паузы после неудач (5 минут; после отказа в ключе — до смены ключа) выдерживает сам скрипт.
    func sendLogsIfNeeded() {
        guard Date().timeIntervalSince(lastLogCheck) >= 30 else { return }
        lastLogCheck = Date()
        guard serverReady(), logSender?.isRunning != true, journalUnsent() else { return }
        let p = scriptProcess(["send-logs", "--auto"])
        p.standardOutput = FileHandle.nullDevice   // скрипт сам пишет в logs/send-logs.log
        p.standardError = FileHandle.nullDevice
        try? p.run()
        logSender = p
    }

    @objc func retryUpload() { run(["upload"]) }

    func run(_ args: [String], then: ((Bool) -> Void)? = nil) {
        busy = true
        refresh()
        let p = scriptProcess(args)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.terminationHandler = { proc in
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                if proc.terminationStatus != 0 {
                    // Подробности пишет сам скрипт; здесь — то, что увидел пользователь. «off» и «name» — с именем записи.
                    logEvent("error", "action_failed", "Команда «\(args.first ?? "")» завершилась с ошибкой — показано окно",
                             session: ["off", "name"].contains(args.first ?? "") ? recordingName() : nil,
                             details: ["exit": Int(proc.terminationStatus), "output": String(out.suffix(1500))])
                    self.alert(out)
                }
                then?(proc.terminationStatus == 0)
            }
        }
        do { try p.run() } catch {
            busy = false; refresh()
            logEvent("error", "action_failed", "Не удалось запустить call-recorder.sh", details: ["error": error.localizedDescription])
            alert("Не удалось запустить \(script): \(error.localizedDescription)")
        }
    }

    func refresh() {
        let names = runningProcessNames()
        let rec = names.contains("CallTap")
        liveRunning = names.contains("LiveStream")
        if rec && !recording { recordingStart = newestFile(in: currentDir, ext: "wav").map(creationDate) ?? Date() }
        if !rec { recordingStart = nil }
        if recording && !rec { noteIfCaptureDied() }
        recording = rec
        sendLogsIfNeeded()
        watchCall()
        if busy {
            showButton("hourglass", title: "", toolTip: "Запись звонков: подождите…")
        } else if recording {
            let silent = micSilent()
            showButton("record.circle.fill", red: true, title: " " + elapsed() + (silent ? " ⚠︎" : ""),
                       toolTip: silent ? "Идёт запись, но микрофон молчит — разрешите CallTap доступ к микрофону (клик → меню)"
                                       : "Идёт запись звонка. Клик — меню, там «Завершить запись»")
        } else if callActive {
            showButton("record.circle", red: true, title: " Записать", toolTip: "Идёт звонок. Клик — начать запись, правый клик — меню")
        } else {
            showButton("record.circle", title: "", toolTip: "Запись звонков. Клик — начать запись, правый клик — меню")
        }
    }

    /// Значок и надпись на кнопке. Перерисовываем, только если что-то изменилось: иначе строка меню
    /// перерисовывалась бы каждую секунду впустую.
    private func showButton(_ name: String, red: Bool = false, title: String, toolTip: String) {
        let state = "\(name)|\(red)|\(title)|\(toolTip)"
        guard state != shownButton, let b = item.button else { return }
        shownButton = state
        b.image = symbol(name, red: red)
        b.title = title
        b.toolTip = toolTip
    }

    /// Раз в секунду: идёт ли звонок. Если звонок, который шёл во время записи, закончился и 2 с не возобновился
    /// (короткие перерывы звука не в счёт), запись останавливается сама; окно имени, если открыто, закрывается.
    private func watchCall() {
        callActive = calls.callActive
        if !recording {
            callSeenWhileRecording = false
            callEndedAt = nil
            if nameAlert != nil { NSApp.abortModal() }   // CallTap завершился, пока спрашивали имя
            return
        }
        if callActive { callSeenWhileRecording = true; callEndedAt = nil; return }
        guard callSeenWhileRecording, autoStopEnabled(), !busy else { return }
        let ended = callEndedAt ?? Date()
        callEndedAt = ended
        guard Date().timeIntervalSince(ended) >= 2 else { return }
        if nameAlert != nil { stopAfterNameAlert = true; NSApp.abortModal() } else { autoStop() }
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
        statusMenuItem = add(statusText(), nil)
        if recording {
            menu.addItem(menuLevelsItem)
            if micSilent() {
                _ = add("⚠︎ Микрофон молчит — ваш голос не пишется", nil)
                _ = add("Открыть настройки доступа к микрофону…", #selector(openMicSettings))
            }
        }
        if !recording, let upload = lastUpload() {
            switch upload.state {
            case "uploading": _ = add("☁︎ Запись отправляется на сервер…", nil)
            case "ok": _ = add("☁︎ Запись отправлена на сервер", nil)
            default: _ = add("⚠︎ Запись не отправлена на сервер — повторить", #selector(retryUpload), enabled: !busy)
            }
        }
        if let problem = journalProblem() {
            _ = add(problem.text, problem.keyProblem ? #selector(showServerSettings) : nil)
        }
        menu.addItem(.separator())
        // Главное действие — со значком (● записать / ■ остановить) и полужирным, чтобы сразу бросалось в глаза.
        let action = add(recording ? "Завершить запись" : "Начать запись", #selector(toggle), enabled: !busy)
        action.image = recording ? symbol("stop.circle.fill") : symbol("record.circle.fill", red: true)
        let menuFont = NSFont.menuFont(ofSize: 0)
        action.attributedTitle = NSAttributedString(string: action.title,
                                                    attributes: [.font: NSFont.systemFont(ofSize: menuFont.pointSize, weight: .semibold)])
        _ = add("Показать детали…", #selector(showDetails))
        menu.addItem(.separator())
        _ = add("Открыть папку с записями", #selector(openFolder))
        _ = add("Показать последнюю запись", #selector(revealLatest), enabled: latestRecording() != nil)
        menu.addItem(.separator())
        let split = add("Сохранять голоса отдельно (я / собеседник)", #selector(toggleSplit))
        split.state = splitEnabled() ? .on : .off
        let live = add("Прямой эфир (звук на сервер во время записи)", #selector(toggleLive))
        live.state = liveEnabled() ? .on : .off
        let autoStop = add("Останавливать запись, когда звонок закончился", #selector(toggleAutoStop))
        autoStop.state = autoStopEnabled() ? .on : .off
        _ = add(serverReady() ? "Сервер и ключ…" : "Сервер и ключ… (не заданы)", #selector(showServerSettings))
        let login = add("Запускать при входе в систему", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        _ = add("Убрать кнопку (запись не остановится)", #selector(quit))
    }

    @objc func showDetails() {
        if detailsWindow == nil { detailsWindow = DetailsWindow(app: self) }
        detailsWindow?.show()
    }

    @objc func toggleSplit() { setSplitEnabled(!splitEnabled()) }

    @objc func toggleLive() { setLive(!liveEnabled()) }

    @objc func toggleAutoStop() { setAutoStopEnabled(!autoStopEnabled()) }

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
