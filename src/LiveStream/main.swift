// LiveStream — «прямой эфир»: пока идёт запись, шлёт обе дорожки звонка на сервер кусками по 0,5 с.
// Читает WAV, который параллельно пишет CallTap (16 бит, канал 1 — собеседник, канал 2 — микрофон), поэтому
// с CallTap никак не связан: если эфир упадёт или зависнет, запись этого не заметит.
//   LiveStream <файл.wav> <сессия> <адрес сервера>
// Ключ берётся из ~/.call-recorder/inbox-token (папку можно подменить CALL_RECORDER_DIR) и никуда не выводится. Протокол — docs/LIVE.md на сервере:
//   POST <сервер>/api/live/chunk?session=<сессия>&track=me|them&seq=<N>, тело — PCM s16le, 16 кГц, моно.
// Остановка: SIGTERM — дочитать хвост файла, отправить последний кусок и выйти.
import AVFoundation
import Foundation

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
let token: String = {
    let t = (try? String(contentsOfFile: appDir + "/inbox-token", encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if t.isEmpty { log("❌ нет ключа сервера (~/.call-recorder/inbox-token)"); exit(1) }
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
    func set(_ state: String) {
        lock.lock(); defer { lock.unlock() }
        // Повторяем запись и при том же состоянии: окно по времени изменения файла видит, что эфир жив.
        try? (state + "\n").write(toFile: statusPath, atomically: true, encoding: .utf8)
        if state != last { log("эфир: \(state)"); last = state }
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
            let code = post(req, data)
            switch code {
            case 200: status.set("on"); return
            case 409: log("[\(track)] сервер: разговор уже закрыт (409) — эфир остановлен"); status.set("stopped"); stopAll(); return
            case 403: log("[\(track)] сервер: нет доступа (403) — проверьте ключ"); status.set("error"); stopAll(); return
            case 400, 404, 413: log("[\(track)] сервер отклонил кусок \(seq): \(code)"); return
            default:
                status.set("error")
                if attempt < 3 { Thread.sleep(forTimeInterval: 0.25 * Double(1 << attempt)) }
            }
        }
        log("[\(track)] кусок \(seq) не отправлен после 3 повторов")
    }

    /// Синхронный POST; возвращает HTTP-код или 0 при сетевой ошибке.
    private func post(_ req: URLRequest, _ data: Data) -> Int {
        let done = DispatchSemaphore(value: 0)
        var code = 0
        URLSession.shared.uploadTask(with: req, from: data) { _, resp, _ in
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        done.wait()
        return code
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
            guard channels == 2, bits == 16, rate > 0 else { log("❌ неожиданный формат WAV: \(channels) кан., \(bits) бит"); return nil }
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
if !me.stopped { status.set("stopped") }
log("эфир завершён")
_ = sigs
exit(0)
