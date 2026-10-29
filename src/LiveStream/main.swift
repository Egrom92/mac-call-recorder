// LiveStream — «прямой эфир»: пока идёт запись, шлёт обе дорожки звонка на сервер кусками по 0,5 с.
// Читает WAV, который параллельно пишет CallTap (16 бит, канал 1 — собеседник, канал 2 — микрофон), поэтому
// с CallTap никак не связан: если эфир упадёт или зависнет, запись этого не заметит.
//   LiveStream <файл.wav> <сессия> <адрес сервера>
// Ключ берётся из ~/.call-recorder/inbox-token (папку можно подменить CALL_RECORDER_DIR) и никуда не выводится. Протокол — docs/LIVE.md на сервере:
//   POST <сервер>/api/live/chunk?session=<сессия>&track=me|them&seq=<N>, тело — PCM s16le, 16 кГц, моно.
// Остановка: SIGTERM — дочитать хвост файла, отправить последний кусок и выйти.
import AVFoundation
import Foundation
import SystemConfiguration

setvbuf(stdout, nil, _IOLBF, 0)

// Папка программы; CALL_RECORDER_DIR подменяет её в тестах, чтобы не трогать настоящий ключ.
let appDir = ProcessInfo.processInfo.environment["CALL_RECORDER_DIR"]
    ?? FileManager.default.homeDirectoryForCurrentUser.path + "/.call-recorder"
let statusPath = appDir + "/logs/live-status"
let timeFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
func log(_ s: String) { print("\(timeFormatter.string(from: Date())) \(s)") }

let args = CommandLine.arguments
guard args.count == 4 else { print("использование: LiveStream <файл.wav> <сессия> <адрес сервера>"); exit(2) }
let wavPath = args[1], session = args[2], server = args[3].trimmingCharacters(in: CharacterSet(charactersIn: "/"))

// MARK: - Журнал ошибок

let errorLogPath = appDir + "/logs/errors.jsonl"
let isoTime: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.timeZone = .current; return f }()
let computerName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
let appVersion = ((try? String(contentsOfFile: appDir + "/version", encoding: .utf8)) ?? "dev").trimmingCharacters(in: .whitespacesAndNewlines)

/// Событие в общий журнал ошибок logs/errors.jsonl — строка JSON (формат — README, «Журнал ошибок»).
/// Строка пишется одним write() в файл с O_APPEND, поэтому строки разных процессов не перемешиваются.
func logEvent(_ level: String, _ event: String, _ message: String, details: [String: Any] = [:]) {
    var e: [String: Any] = ["id": UUID().uuidString.lowercased(), "time": isoTime.string(from: Date()), "level": level,
                            "source": "livestream", "event": event, "message": message, "session": session,
                            "host": computerName, "version": appVersion]
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

/// Сбои эфира без лавины: первый случай каждого вида пишется сразу, повторы того же вида — не чаще раза в минуту
/// (с числом пропущенных). Все случаи считаются для итога в конце эфира.
final class Problems {
    private let lock = NSLock()
    private var lastLogged: [String: Date] = [:]
    private var skipped: [String: Int] = [:]
    private var counts: [String: Int] = [:]
    var total: [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }

    func report(_ level: String, _ event: String, kind: String, _ message: String, _ details: [String: Any]) {
        lock.lock()
        counts[kind, default: 0] += 1
        if let t = lastLogged[kind], Date().timeIntervalSince(t) < 60 { skipped[kind, default: 0] += 1; lock.unlock(); return }
        lastLogged[kind] = Date()
        var d = details
        if let n = skipped.removeValue(forKey: kind) { d["repeats_not_logged"] = n }
        lock.unlock()
        logEvent(level, event, message, details: d)
    }
}
let problems = Problems()
let startedAt = Date()

let token: String = {
    let t = (try? String(contentsOfFile: appDir + "/inbox-token", encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if t.isEmpty {
        log("❌ нет ключа сервера (~/.call-recorder/inbox-token)")
        logEvent("error", "live_no_token", "Прямой эфир не начался: нет ключа сервера")
        exit(1)
    }
    return t
}()

let outRate = 16_000.0
let chunkBytes = 16_000            // 0,5 с при 16 кГц, 16 бит, моно
let maxQueued = 20                 // ~10 с: при плохой сети старые куски выбрасываются, свежие важнее

// MARK: - Состояние для окна программы

/// Пишет в logs/live-status одно слово: wait — ещё не отправлено ни куска, on — куски уходят, error — нет связи,
/// stopped — эфир закончен (или сервер закрыл разговор).
final class Status {
    private let lock = NSLock()
    private var last = ""
    private var lostAt: Date?
    func set(_ state: String) {
        lock.lock()
        // Повторяем запись и при том же состоянии: окно по времени изменения файла видит, что эфир жив.
        try? (state + "\n").write(toFile: statusPath, atomically: true, encoding: .utf8)
        var restoredAfter: Int?
        if state != last {
            log("эфир: \(state)")
            if state == "error" && last == "on" { lostAt = Date() }
            if state == "on", let t = lostAt { restoredAfter = Int(Date().timeIntervalSince(t).rounded()); lostAt = nil }
            last = state
        }
        lock.unlock()
        if let s = restoredAfter {
            problems.report("info", "live_reconnected", kind: "reconnected", "Связь с сервером восстановилась", ["offline_seconds": s])
        }
    }
}
let status = Status()

// MARK: - Отправка одной дорожки

/// Очередь кусков одной дорожки: отправляет по одному, следующий — после ответа на предыдущий.
final class TrackSender {
    let track: String
    private var queue: [(seq: Int, data: Data)] = []
    private var nextSeq = 0
    private let cond = NSCondition()
    private var finishing = false
    private(set) var dropped = 0
    private(set) var sent = 0
    private(set) var lost = 0
    var stopAll: () -> Void = {}
    var stopped = false

    init(track: String) { self.track = track }

    func push(_ data: Data) {
        cond.lock()
        queue.append((nextSeq, data))
        nextSeq += 1
        if queue.count > maxQueued { dropped += queue.count - maxQueued; queue.removeFirst(queue.count - maxQueued) }
        cond.signal()
        cond.unlock()
    }

    func finish() { cond.lock(); finishing = true; cond.signal(); cond.unlock() }

    func run() {
        while true {
            cond.lock()
            while queue.isEmpty && !finishing && !stopped { cond.wait() }
            if stopped || (queue.isEmpty && finishing) { cond.unlock(); return }
            let item = queue.removeFirst()
            cond.unlock()
            send(item.seq, item.data)
        }
    }

    /// До 3 повторов при сетевой ошибке или 5xx (тот же seq — сервер повтор пропустит), потом следующий кусок.
    private func send(_ seq: Int, _ data: Data) {
        var comps = URLComponents(string: server + "/api/live/chunk")!
        comps.queryItems = [URLQueryItem(name: "session", value: session), URLQueryItem(name: "track", value: track),
                            URLQueryItem(name: "seq", value: String(seq))]
        var req = URLRequest(url: comps.url!, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        for attempt in 0...3 {
            if stopped { return }
            let (code, body, error) = post(req, data)
            let details: [String: Any] = ["track": track, "seq": seq, "http": code, "attempt": attempt + 1, "response": body]
            switch code {
            case 200: sent += 1; status.set("on"); return
            case 409:
                log("[\(track)] сервер: разговор уже закрыт (409) — эфир остановлен"); status.set("stopped")
                problems.report("warning", "live_closed", kind: "409", "Сервер закрыл разговор (409) — эфир остановлен", details)
                stopAll(); return
            case 403:
                log("[\(track)] сервер: нет доступа (403) — проверьте ключ"); status.set("error")
                problems.report("error", "live_forbidden", kind: "403", "Сервер не принял ключ (403) — эфир остановлен", details)
                stopAll(); return
            case 400, 404, 413:
                log("[\(track)] сервер отклонил кусок \(seq): \(code)")
                problems.report("warning", "live_rejected", kind: "\(code)", "Сервер отклонил кусок эфира (\(code))", details)
                return
            default:
                status.set("error")
                if code == 0 {
                    problems.report("warning", "live_network_error", kind: "net: " + (error ?? "?"),
                                    "Нет связи с сервером: " + (error ?? "неизвестная ошибка"), details)
                } else {
                    problems.report("warning", "live_http_error", kind: "\(code)", "Сервер ответил ошибкой \(code)", details)
                }
                if attempt < 3 { Thread.sleep(forTimeInterval: 0.25 * Double(1 << attempt)) }
            }
        }
        lost += 1
        log("[\(track)] кусок \(seq) не отправлен после 3 повторов")
        problems.report("warning", "live_chunk_lost", kind: "lost", "Кусок эфира пропущен после 3 повторов",
                        ["track": track, "seq": seq])
    }

    /// Синхронный POST; возвращает HTTP-код (0 при сетевой ошибке), начало ответа сервера и текст сетевой ошибки.
    private func post(_ req: URLRequest, _ data: Data) -> (Int, String, String?) {
        let done = DispatchSemaphore(value: 0)
        var result: (Int, String, String?) = (0, "", nil)
        URLSession.shared.uploadTask(with: req, from: data) { body, resp, error in
            let text = body.flatMap { String(data: $0.prefix(300), encoding: .utf8) } ?? ""
            result = ((resp as? HTTPURLResponse)?.statusCode ?? 0, text,
                      error.map { e in "\(e.localizedDescription) (\((e as NSError).code))" })
            done.signal()
        }.resume()
        done.wait()
        return result
    }
}

// MARK: - Пересчёт в 16 кГц моно int16

/// Одна дорожка: Float32 моно исходной частоты → Int16 моно 16 кГц (AVAudioConverter, с фильтром против наложения).
final class TrackResampler {
    private let converter: AVAudioConverter
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat
    private var pcm = Data()          // накопленный PCM 16 кГц, режется на куски по chunkBytes
    let sender: TrackSender

    init(rate: Double, sender: TrackSender) {
        inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: outRate, channels: 1, interleaved: true)!
        converter = AVAudioConverter(from: inFormat, to: outFormat)!
        self.sender = sender
    }

    func feed(_ samples: [Float], final: Bool = false) {
        if !samples.isEmpty {
            let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count))!
            input.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            convert(input)
        }
        if final {
            convert(nil)
            if pcm.count >= 3_200 { sender.push(pcm) }   // хвост ≥ 0,1 с — сервер принимает куски 0,1–1 с
            pcm.removeAll()
        }
    }

    private func convert(_ input: AVAudioPCMBuffer?) {
        let capacity = AVAudioFrameCount(Double(input?.frameLength ?? 0) * outRate / inFormat.sampleRate) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)!
        var given = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if let input, !given { given = true; status.pointee = .haveData; return input }
            status.pointee = input == nil ? .endOfStream : .noDataNow
            return nil
        }
        if output.frameLength > 0 {
            pcm.append(Data(bytes: output.int16ChannelData![0], count: Int(output.frameLength) * 2))
        }
        while pcm.count >= chunkBytes {
            sender.push(pcm.prefix(chunkBytes))
            pcm.removeFirst(chunkBytes)
        }
    }
}

// MARK: - Чтение растущего WAV

struct WavInfo { let dataStart: UInt64; let rate: Double; let channels: Int }

/// Заголовок WAV: формат из блока fmt, начало звука — блок data (перед ним у CallTap есть блок FLLR).
func readWavInfo(_ h: FileHandle) -> WavInfo? {
    guard (try? h.seek(toOffset: 0)) != nil, let head = try? h.read(upToCount: 65_536), head.count > 44,
          head.prefix(4) == Data("RIFF".utf8) else { return nil }
    let b = [UInt8](head)
    func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
    func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
    var off = 12, rate = 0.0, channels = 0, bits = 0
    while off + 8 <= b.count {
        let id = String(bytes: b[off..<off + 4], encoding: .ascii)
        let len = u32(off + 4)
        if id == "fmt " { channels = u16(off + 10); rate = Double(u32(off + 12)); bits = u16(off + 22) }
        if id == "data" {
            guard channels == 2, bits == 16, rate > 0 else {
                log("❌ неожиданный формат WAV: \(channels) кан., \(bits) бит")
                logEvent("error", "live_bad_wav", "Прямой эфир не начался: неожиданный формат записи",
                         details: ["channels": channels, "bits": bits, "rate": rate])
                return nil
            }
            return WavInfo(dataStart: UInt64(off + 8), rate: rate, channels: channels)
        }
        off += 8 + len + (len & 1)
    }
    return nil
}

// MARK: - Главный цикл

let me = TrackSender(track: "me"), them = TrackSender(track: "them")
let senders = [me, them]
for s in senders { s.stopAll = { senders.forEach { $0.stopped = true; $0.finish() } } }
let threads = senders.map { s in Thread { s.run() } }
threads.forEach { $0.start() }

var stopRequested = false
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let sigs = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
    let src = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.global())
    src.setEventHandler { stopRequested = true }
    src.resume()
    return src
}

log("эфир для «\(session)»: \(server)")
status.set("wait")

// Ждём, пока CallTap создаст файл и запишет заголовок.
var handle: FileHandle?
var info: WavInfo?
while info == nil && !stopRequested {
    if handle == nil { handle = FileHandle(forReadingAtPath: wavPath) }
    if let h = handle { info = readWavInfo(h) }
    if info == nil { Thread.sleep(forTimeInterval: 0.1) }
}
guard let h = handle, let wav = info else { status.set("stopped"); exit(0) }
log("исходный звук: \(Int(wav.rate)) Гц, \(wav.channels) канала → 16000 Гц моно")

let themResampler = TrackResampler(rate: wav.rate, sender: them)   // канал 1 — собеседник
let meResampler = TrackResampler(rate: wav.rate, sender: me)       // канал 2 — микрофон
var position = wav.dataStart
let frameBytes = UInt64(2 * wav.channels)

/// Читает всё, что CallTap дописал с прошлого раза (целыми кадрами), и раздаёт по дорожкам.
func pump() {
    guard let size = try? h.seekToEnd(), size >= position + frameBytes else { return }
    let length = (size - position) / frameBytes * frameBytes
    guard (try? h.seek(toOffset: position)) != nil, let data = try? h.read(upToCount: Int(length)), !data.isEmpty else { return }
    position += UInt64(data.count)
    let frames = data.count / Int(frameBytes)
    var far = [Float](repeating: 0, count: frames), mic = [Float](repeating: 0, count: frames)
    data.withUnsafeBytes { raw in
        for i in 0..<frames {
            far[i] = Float(raw.loadUnaligned(fromByteOffset: i * 4, as: Int16.self)) / 32768
            mic[i] = Float(raw.loadUnaligned(fromByteOffset: i * 4 + 2, as: Int16.self)) / 32768
        }
    }
    themResampler.feed(far)
    meResampler.feed(mic)
}

while !stopRequested && !me.stopped {
    pump()
    Thread.sleep(forTimeInterval: 0.1)
}
// Остановка записи: дочитать хвост, отправить последний кусок, дождаться очередей (не дольше 5 с).
pump()
themResampler.feed([], final: true)
meResampler.feed([], final: true)
senders.forEach { $0.finish() }
let deadline = Date().addingTimeInterval(5)
while threads.contains(where: { !$0.isFinished }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
if me.dropped + them.dropped > 0 { log("выброшено из-за отставания сети: me \(me.dropped), them \(them.dropped)") }
// Итог по звонку: сколько кусков ушло, сколько потеряно и каких сбоев сколько было.
let dropped = me.dropped + them.dropped, lostChunks = me.lost + them.lost, kinds = problems.total.filter { $0.key != "reconnected" }
let clean = kinds.isEmpty && dropped == 0
logEvent(clean ? "info" : "warning", "live_summary", clean ? "Прямой эфир прошёл без сбоев" : "Прямой эфир прошёл со сбоями",
         details: ["seconds": Int(Date().timeIntervalSince(startedAt)), "sent_me": me.sent, "sent_them": them.sent,
                   "lost": lostChunks, "dropped_queue": dropped, "problems": kinds])
if !me.stopped { status.set("stopped") }
log("эфир завершён")
_ = sigs
exit(0)
