// «Запись звонков» — кнопка в строке меню: клик начинает или останавливает запись (~/.call-recorder/call-recorder.sh on/off),
// иконка показывает состояние: ◯ — запись не идёт, красный ● с таймером — идёт запись.
// Правый клик (или Control-клик) открывает меню.
import AppKit
import ServiceManagement

let home = FileManager.default.homeDirectoryForCurrentUser.path
let script = home + "/.call-recorder/call-recorder.sh"
let recDir = home + "/Movies/Записи звонков"
let currentDir = home + "/.call-recorder/current"   // WAV текущей записи

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

func latestRecording() -> URL? { newestFile(in: recDir, ext: "m4a") }

func symbol(_ name: String, red: Bool = false) -> NSImage? {
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: "Запись звонков") else { return nil }
    if red, let colored = img.withSymbolConfiguration(.init(paletteColors: [.systemRed])) {
        colored.isTemplate = false
        return colored
    }
    img.isTemplate = true
    return img
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let menu = NSMenu()
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
            b.image = symbol("record.circle.fill", red: true)
            b.title = " " + elapsed()
            b.toolTip = "Идёт запись звонка. Клик — остановить и сохранить"
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
        menu.addItem(.separator())
        _ = add(recording ? "Остановить и сохранить" : "Начать запись", #selector(toggle), enabled: !busy)
        menu.addItem(.separator())
        _ = add("Открыть папку с записями", #selector(openFolder))
        _ = add("Показать последнюю запись", #selector(revealLatest), enabled: latestRecording() != nil)
        menu.addItem(.separator())
        let login = add("Запускать при входе в систему", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        _ = add("Убрать кнопку (запись не остановится)", #selector(quit))
    }

    @objc func openFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: recDir)) }

    @objc func revealLatest() {
        guard let m4a = latestRecording() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([m4a])
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
