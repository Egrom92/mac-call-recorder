// CallTap: записывает звонок — голос собеседника через Core Audio Process Tap (звук приложений Mac) и микрофон;
// режим bridge пересылает звук Mac в BlackHole 2ch для записи через OBS.
//   CallTap record <файл.wav>               — записать звонок (канал 1 — собеседник, 2 — микрофон) до SIGTERM
//   CallTap bridge                          — пересылать звук в BlackHole до остановки (SIGTERM / SIGINT)
//   CallTap procs                           — показать процессы, которые работают со звуком
//   CallTap diag <секунд> <папка>           — диагностика: уровни общего tap и каждого процесса, WAV-файлы
import AudioToolbox
import CoreAudio
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let sys = AudioObjectID(kAudioObjectSystemObject)
let blackHoleUID = "BlackHole2ch_UID"
let obsBundleID = "com.obsproject.obs-studio"

let timeFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
func log(_ s: String) { print("\(timeFormatter.string(from: Date())) \(s)") }

func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getIDs(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var a = addr(sel, scope); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

func getValue<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var a = addr(sel, scope); var v = initial; var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
}

func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = addr(sel); var v: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr, let r = v else { return "" }
    return r.takeRetainedValue() as String
}

// MARK: - Устройства

struct Device { let id: AudioObjectID; let name: String; let uid: String }

func allDevices() -> [Device] {
    getIDs(sys, kAudioHardwarePropertyDevices).map {
        Device(id: $0, name: getString($0, kAudioObjectPropertyName), uid: getString($0, kAudioDevicePropertyDeviceUID))
    }
}
func deviceName(_ id: AudioObjectID) -> String { let n = getString(id, kAudioObjectPropertyName); return n.isEmpty ? "#\(id)" : n }
func hasStreams(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool { !getIDs(id, kAudioDevicePropertyStreams, scope).isEmpty }
func defaultDevice(_ sel: AudioObjectPropertySelector) -> AudioObjectID { getValue(sys, sel, AudioObjectID(0)) ?? 0 }
func setDefaultDevice(_ sel: AudioObjectPropertySelector, _ id: AudioObjectID) {
    var a = addr(sel); var d = id
    AudioObjectSetPropertyData(sys, &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &d)
}

// MARK: - Процессы

struct AudioProcess {
    let obj: AudioObjectID, pid: pid_t, bundle: String, name: String
    let runningIn: Bool, runningOut: Bool
    let inDevices: [AudioObjectID], outDevices: [AudioObjectID]
}

func processName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "pid\(pid)" }
    return (String(cString: buf) as NSString).lastPathComponent
}

func audioProcesses() -> [AudioProcess] {
    getIDs(sys, kAudioHardwarePropertyProcessObjectList).map { obj in
        let pid = getValue(obj, kAudioProcessPropertyPID, pid_t(0)) ?? 0
        return AudioProcess(
            obj: obj, pid: pid, bundle: getString(obj, kAudioProcessPropertyBundleID), name: processName(pid),
            runningIn: (getValue(obj, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0) != 0,
            runningOut: (getValue(obj, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0,
            inDevices: getIDs(obj, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput),
            outDevices: getIDs(obj, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput))
    }
}

func processObject(_ pid: pid_t) -> AudioObjectID? {
    var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var p = pid; var obj = AudioObjectID(kAudioObjectUnknown); var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = AudioObjectGetPropertyData(sys, &a, UInt32(MemoryLayout<pid_t>.size), &p, &size, &obj)
    return st == noErr && obj != kAudioObjectUnknown ? obj : nil
}

// MARK: - Tap + приватное aggregate-устройство

func formatString(_ f: AudioStreamBasicDescription?) -> String {
    guard let f else { return "?" }
    let ni = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    let fl = f.mFormatFlags & kAudioFormatFlagIsFloat != 0
    return "\(Int(f.mSampleRate))Hz/\(f.mChannelsPerFrame)ch/\(f.mBitsPerChannel)\(fl ? "f" : "i")\(ni ? "/NI" : "")"
}

func db(_ v: Float) -> String { v < 0.00001 ? "  -inf" : String(format: "%6.1f", 20 * log10(v)) }

final class TapCapture {
    let label: String
    private let forward: Bool
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var file: ExtAudioFileRef?
    // Уровни пишет аудиопоток, читает таймер раз в секунду; для измерений гонки здесь безвредны.
    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var samples = 0
    private let inputPeaks = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    private(set) var info = ""

    init?(label: String, tap desc: CATapDescription, clockUID: String, wavPath: String? = nil, forward: Bool = false) {
        self.label = label
        self.forward = forward
        inputPeaks.initialize(repeating: 0, count: 8)
        desc.uuid = UUID()
        desc.name = "CallTap \(label)"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { log("[\(label)] не удалось создать tap: \(st)"); return nil }
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CallTap \(label)",
            kAudioAggregateDeviceUIDKey: "CallTap-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard st == noErr else { log("[\(label)] не удалось создать aggregate: \(st)"); stop(); return nil }
        Thread.sleep(forTimeInterval: 0.3)

        let rate = getValue(aggID, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? 0
        let tapFormat = getValue(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        let inFormats = getIDs(aggID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
            .map { getValue($0, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()) }
        let outFormats = getIDs(aggID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
            .map { getValue($0, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()) }
        info = "rate=\(Int(rate)) tap=\(formatString(tapFormat)) in=\(inFormats.map(formatString)) out=\(outFormats.map(formatString))"
        if let wavPath, let last = inFormats.last, let clientFormat = last { file = makeWav(wavPath, clientFormat) }

        st = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggID, nil) { [unowned self] _, inData, _, outData, _ in
            self.render(inData, outData)
        }
        guard st == noErr else { log("[\(label)] не удалось создать IOProc: \(st)"); stop(); return nil }
        st = AudioDeviceStart(aggID, ioProc)
        guard st == noErr else { log("[\(label)] не удалось запустить: \(st)"); stop(); return nil }
    }

    private func makeWav(_ path: String, _ client: AudioStreamBasicDescription) -> ExtAudioFileRef? {
        var clientFormat = client
        let ch = client.mChannelsPerFrame
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: client.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2 * ch, mFramesPerPacket: 1, mBytesPerFrame: 2 * ch,
            mChannelsPerFrame: ch, mBitsPerChannel: 16, mReserved: 0)
        var f: ExtAudioFileRef?
        guard ExtAudioFileCreateWithURL(URL(fileURLWithPath: path) as CFURL, kAudioFileWAVEType, &fileFormat, nil,
                                        AudioFileFlags.eraseFile.rawValue, &f) == noErr, let f else { return nil }
        ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat,
                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)
        ExtAudioFileWriteAsync(f, 0, nil)
        return f
    }

    private func render(_ inData: UnsafePointer<AudioBufferList>, _ outData: UnsafeMutablePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        let outs = UnsafeMutableAudioBufferListPointer(outData)
        for o in outs { if let d = o.mData { memset(d, 0, Int(o.mDataByteSize)) } }
        for (i, b) in ins.enumerated() where i < 8 {
            guard let d = b.mData else { continue }
            let f = d.assumingMemoryBound(to: Float.self)
            var pk: Float = 0
            for j in 0..<Int(b.mDataByteSize) / 4 { pk = max(pk, abs(f[j])) }
            inputPeaks[i] = max(inputPeaks[i], pk)
        }
        // В aggregate сначала идут потоки подустройства (BlackHole), последним — поток tap.
        guard let tapBuf = ins.last, let tapData = tapBuf.mData else { return }
        let n = Int(tapBuf.mDataByteSize) / 4
        let tap = tapData.assumingMemoryBound(to: Float.self)
        var ss: Double = 0, pk: Float = 0
        for j in 0..<n { let v = tap[j]; ss += Double(v * v); pk = max(pk, abs(v)) }
        peak = max(peak, pk); sumSquares += ss; samples += n

        let tapCh = max(Int(tapBuf.mNumberChannels), 1)
        if forward {
            for o in outs {
                guard let od = o.mData else { continue }
                let out = od.assumingMemoryBound(to: Float.self)
                let outCh = max(Int(o.mNumberChannels), 1)
                let frames = min(n / tapCh, Int(o.mDataByteSize) / 4 / outCh)
                for fr in 0..<frames {
                    for c in 0..<outCh { out[fr * outCh + c] = tap[fr * tapCh + min(c, tapCh - 1)] }
                }
            }
        }
        if let file {
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: tapBuf)
            ExtAudioFileWriteAsync(file, UInt32(n / tapCh), &abl)
        }
    }

    func takeLevels() -> (peak: Float, rms: Float, inputs: [Float]) {
        let r = (peak, samples > 0 ? Float(sqrt(sumSquares / Double(samples))) : 0, (0..<8).map { inputPeaks[$0] })
        peak = 0; sumSquares = 0; samples = 0
        for i in 0..<8 { inputPeaks[i] = 0 }
        return r
    }

    func stop() {
        if let ioProc { AudioDeviceStop(aggID, ioProc); AudioDeviceDestroyIOProcID(aggID, ioProc) }
        ioProc = nil
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = kAudioObjectUnknown }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
        if let file { ExtAudioFileDispose(file) }
        file = nil
    }
}

// MARK: - Запись звонка без OBS

/// Пишет WAV с двумя каналами: 1 — собеседник (общий tap звука Mac), 2 — микрофон.
/// Tap и микрофон собраны в одно aggregate-устройство с часами BlackHole, поэтому идут синхронно.
/// Если устройство перестаёт отдавать звук (AirPods в этот момент переключили режим или переподключились),
/// его пересоздают через restart(), а запись продолжается в тот же файл.
final class CallRecorder {
    private let exclude: [AudioObjectID]
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var file: ExtAudioFileRef?
    private let maxFrames = 16384
    private let frames = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 16384)
    private var farPeak: Float = 0
    private var micPeak: Float = 0
    /// Сколько кадров записано: растёт в аудиопотоке, сторож в runRecord читает его раз в секунду.
    private(set) var framesWritten = 0
    private(set) var info = ""

    init?(path: String, micUID: String, exclude: [AudioObjectID]) {
        self.exclude = exclude
        guard let rate = startCapture(micUID: micUID) else { stopCapture(); return nil }
        var client = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        guard ExtAudioFileCreateWithURL(URL(fileURLWithPath: path) as CFURL, kAudioFileWAVEType, &fileFormat, nil,
                                        AudioFileFlags.eraseFile.rawValue, &file) == noErr, let file else {
            log("⚠️ не удалось создать файл \(path)"); stopCapture(); return nil
        }
        ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        ExtAudioFileWriteAsync(file, 0, nil)
        guard startIO() else { stop(); return nil }
    }

    /// Создаёт tap и aggregate (BlackHole — часы, микрофон, tap) и возвращает частоту устройства; звук ещё не идёт.
    private func startCapture(micUID: String) -> Float64? {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.uuid = UUID()
        desc.name = "CallTap record"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { log("⚠️ не удалось создать tap: \(st)"); return nil }
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CallTap record",
            kAudioAggregateDeviceUIDKey: "CallTap-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: blackHoleUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: blackHoleUID],
                [kAudioSubDeviceUIDKey: micUID, kAudioSubDeviceDriftCompensationKey: true],
            ],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard st == noErr else { log("⚠️ не удалось создать aggregate: \(st)"); return nil }
        Thread.sleep(forTimeInterval: 0.3)

        let rate = getValue(aggID, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? 48000
        let inFormats = getIDs(aggID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
            .map { getValue($0, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()) }
        info = "rate=\(Int(rate)) in=\(inFormats.map(formatString))"
        // Потоки входа: BlackHole, микрофон, tap.
        guard inFormats.count >= 3 else { log("⚠️ в aggregate нет потока микрофона (\(info))"); return nil }
        return rate
    }

    private func startIO() -> Bool {
        var st = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggID, nil) { [unowned self] _, inData, _, outData, _ in
            self.render(inData, outData)
        }
        guard st == noErr else { log("⚠️ не удалось создать IOProc: \(st)"); return false }
        st = AudioDeviceStart(aggID, ioProc)
        guard st == noErr else { log("⚠️ не удалось запустить захват: \(st)"); return false }
        return true
    }

    /// Пересоздаёт tap и aggregate и снова запускает захват; WAV остаётся тем же.
    func restart(micUID: String) -> Bool {
        stopCapture()
        guard startCapture(micUID: micUID) != nil, startIO() else { stopCapture(); return false }
        return true
    }

    private func render(_ inData: UnsafePointer<AudioBufferList>, _ outData: UnsafeMutablePointer<AudioBufferList>) {
        for o in UnsafeMutableAudioBufferListPointer(outData) { if let d = o.mData { memset(d, 0, Int(o.mDataByteSize)) } }
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard ins.count >= 3, let file, let tapData = ins[ins.count - 1].mData, let micData = ins[1].mData else { return }
        let tapCh = max(Int(ins[ins.count - 1].mNumberChannels), 1), micCh = max(Int(ins[1].mNumberChannels), 1)
        let tap = tapData.assumingMemoryBound(to: Float.self), mic = micData.assumingMemoryBound(to: Float.self)
        let n = min(Int(ins[ins.count - 1].mDataByteSize) / 4 / tapCh, Int(ins[1].mDataByteSize) / 4 / micCh, maxFrames)
        var fp: Float = 0, mp: Float = 0
        for f in 0..<n {
            var far: Float = 0
            for c in 0..<tapCh { far += tap[f * tapCh + c] }
            far /= Float(tapCh)
            let me = mic[f * micCh]
            frames[2 * f] = far
            frames[2 * f + 1] = me
            fp = max(fp, abs(far)); mp = max(mp, abs(me))
        }
        farPeak = max(farPeak, fp); micPeak = max(micPeak, mp)
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(n * 8), mData: frames))
        ExtAudioFileWriteAsync(file, UInt32(n), &abl)
        framesWritten += n
    }

    func takePeaks() -> (far: Float, mic: Float) {
        let r = (farPeak, micPeak)
        farPeak = 0; micPeak = 0
        return r
    }

    private func stopCapture() {
        if let ioProc { AudioDeviceStop(aggID, ioProc); AudioDeviceDestroyIOProcID(aggID, ioProc) }
        ioProc = nil
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = kAudioObjectUnknown }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
    }

    func stop() {
        stopCapture()
        if let file { ExtAudioFileDispose(file) }
        file = nil
    }
}

// MARK: - Команды

var cleanup: () -> Void = {}
var signalSources: [DispatchSourceSignal] = []
func onTerminate(_ body: @escaping () -> Void) {
    cleanup = body
    for s in [SIGTERM, SIGINT, SIGHUP] {
        signal(s, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
        src.setEventHandler { cleanup(); exit(0) }
        src.resume()
        signalSources.append(src)
    }
}

func describe(_ p: AudioProcess) -> String {
    "pid=\(p.pid) \(p.name) [\(p.bundle)] in=\(p.runningIn ? 1 : 0)\(p.inDevices.map(deviceName)) out=\(p.runningOut ? 1 : 0)\(p.outDevices.map(deviceName))"
}

func printProcesses() {
    log("выход: \(deviceName(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice))), вход: \(deviceName(defaultDevice(kAudioHardwarePropertyDefaultInputDevice)))")
    for p in audioProcesses() where p.pid != getpid() { log(describe(p)) }
}

func runBridge() {
    guard let bh = allDevices().first(where: { $0.uid == blackHoleUID }) else { log("❌ BlackHole 2ch не найден"); exit(1) }
    let out = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    if out == bh.id {
        log("⚠️ системный выход «\(deviceName(out))» уже пишет в BlackHole — звук задвоится; выберите выходом AirPods")
    }
    var exclude = processObject(getpid()).map { [$0] } ?? []
    exclude += audioProcesses().filter { $0.bundle == obsBundleID }.map(\.obj)
    guard let t = TapCapture(label: "bridge", tap: CATapDescription(stereoGlobalTapButExcludeProcesses: exclude),
                             clockUID: blackHoleUID, forward: true) else { exit(1) }
    log("✅ мост запущен: весь звук Mac → BlackHole 2ch (\(t.info))")
    onTerminate { t.stop(); log("мост остановлен") }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 10, repeating: 10)
    timer.setEventHandler { let l = t.takeLevels(); log("уровень за 10 с: пик \(db(l.peak)) дБ, rms \(db(l.rms)) дБ") }
    timer.resume()
    keepAlive.append(timer)
}

var keepAlive: [AnyObject] = []

/// Микрофон для записи — AirPods, если подключены, иначе системный вход по умолчанию.
func findMic() -> Device? {
    let devices = allDevices()
    let defaultIn = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    return devices.first(where: { $0.name.contains("AirPods") && hasStreams($0.id, kAudioObjectPropertyScopeInput) })
        ?? devices.first(where: { $0.id == defaultIn })
}

func runRecord(path: String) {
    guard allDevices().contains(where: { $0.uid == blackHoleUID }) else { log("❌ BlackHole 2ch не найден"); exit(1) }
    let exclude = processObject(getpid()).map { [$0] } ?? []
    // AirPods в момент запуска могут переключаться в режим гарнитуры — тогда первая попытка не удаётся.
    var recorder: CallRecorder?
    var micName = ""
    for attempt in 1...3 {
        guard let mic = findMic() else { log("❌ микрофон не найден"); exit(1) }
        micName = mic.name
        recorder = CallRecorder(path: path, micUID: mic.uid, exclude: exclude)
        if recorder != nil { break }
        if attempt < 3 { Thread.sleep(forTimeInterval: 1.5) }
    }
    guard let rec = recorder else { log("❌ не удалось начать запись"); exit(1) }
    log("✅ запись идёт: собеседник (звук Mac) + микрофон «\(micName)» → \(path) (\(rec.info))")
    onTerminate { rec.stop(); log("запись остановлена") }

    var first = true
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 3, repeating: 10)
    timer.setEventHandler {
        let p = rec.takePeaks()
        log("уровень за \(first ? 3 : 10) с: собеседник \(db(p.far)) дБ, микрофон \(db(p.mic)) дБ")
        first = false
    }
    timer.resume()
    keepAlive.append(timer)

    // Сторож: если кадры не поступают (на старте 5 с, дальше 3 с), устройство захвата пересоздаётся.
    // Так бывает, когда AirPods при запуске переключаются в режим гарнитуры или переподключаются посреди записи.
    var lastFrames = 0, lastProgress = Date(), started = false
    let watchdog = DispatchSource.makeTimerSource(queue: .main)
    watchdog.schedule(deadline: .now() + 1, repeating: 1)
    watchdog.setEventHandler {
        let written = rec.framesWritten
        if written != lastFrames { lastFrames = written; lastProgress = Date(); started = true; return }
        let stalled = Date().timeIntervalSince(lastProgress)
        guard stalled >= (started ? 3 : 5) else { return }
        let mic = findMic()
        log("⚠️ звук не поступает \(Int(stalled)) с — перезапускаю захват" + (mic.map { " (микрофон «\($0.name)»)" } ?? ""))
        if let mic, rec.restart(micUID: mic.uid) { log("✅ захват перезапущен") } else { log("⚠️ перезапустить не удалось, попробую ещё раз") }
        lastProgress = Date()
    }
    watchdog.resume()
    keepAlive.append(watchdog)
}

func runDiag(seconds: Int, dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let devices = allDevices()
    guard devices.contains(where: { $0.uid == blackHoleUID }) else { log("❌ BlackHole 2ch не найден"); exit(1) }
    let me = processObject(getpid()).map { [$0] } ?? []
    log("устройства: " + devices.map { "\($0.name)=\($0.uid)#\($0.id)" }.joined(separator: ", "))
    var taps: [(String, TapCapture)] = []
    var attempted = Set<String>()
    func add(_ key: String, _ make: () -> TapCapture?) {
        guard attempted.insert(key).inserted else { return }
        if let t = make() { taps.append((key, t)); log("[\(key)] \(t.info)") }
    }
    add("global") { TapCapture(label: "global", tap: CATapDescription(stereoGlobalTapButExcludeProcesses: me), clockUID: blackHoleUID, wavPath: "\(dir)/global.wav") }
    if let air = devices.first(where: { $0.name.contains("AirPods") && hasStreams($0.id, kAudioObjectPropertyScopeOutput) }) {
        add("dev-airpods") { TapCapture(label: "dev-airpods", tap: CATapDescription(excludingProcesses: me, deviceUID: air.uid, stream: 0), clockUID: blackHoleUID, wavPath: "\(dir)/dev-airpods.wav") }
    }
    let callPattern = try! NSRegularExpression(pattern: "avconference|callservices|facetime|mobilephone|telephony|incall|conversation", options: .caseInsensitive)
    func isCall(_ p: AudioProcess) -> Bool {
        let s = p.name + " " + p.bundle
        return callPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    var tick = 0, callStart: Int?
    var lastActive = "", lastDevices = ""
    onTerminate {
        taps.forEach { $0.1.stop() }
        log("диагностика остановлена")
    }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        tick += 1
        let procs = audioProcesses().filter { $0.pid != getpid() }
        let active = procs.filter { $0.runningIn || $0.runningOut }
        let activeDesc = active.map(describe).joined(separator: "\n    ")
        if activeDesc != lastActive { log("активные процессы:\n    \(activeDesc)"); lastActive = activeDesc }
        let devs = allDevices().map { "\($0.name)#\($0.id)" }.joined(separator: ", ")
        if devs != lastDevices { log("список устройств: \(devs)"); lastDevices = devs }
        for p in active where p.runningOut {
            let key = "\(p.name)#\(p.pid)"
            add(key) { TapCapture(label: key, tap: CATapDescription(stereoMixdownOfProcesses: [p.obj]), clockUID: blackHoleUID,
                                  wavPath: "\(dir)/proc-\(p.name.replacingOccurrences(of: " ", with: "_"))-\(p.pid).wav") }
        }
        // Начало разговора — процесс звонка открыл микрофон (рингтон микрофон не использует).
        if callStart == nil, let c = active.first(where: { isCall($0) && $0.runningIn }) { callStart = tick; log("📞 звонок обнаружен: \(c.name)") }
        var line = "t=\(tick) out=\(deviceName(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice))) in=\(deviceName(defaultDevice(kAudioHardwarePropertyDefaultInputDevice)))"
        for (key, t) in taps {
            let l = t.takeLevels()
            line += " | \(key) \(db(l.peak))/\(db(l.rms))"
        }
        log(line)
        if tick >= seconds { cleanup(); exit(0) }
    }
    timer.resume()
    keepAlive.append(timer)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "" {
case "procs":
    printProcesses(); exit(0)
case "diag":
    runDiag(seconds: args.count > 1 ? Int(args[1]) ?? 60 : 60,
            dir: args.count > 2 ? args[2] : NSTemporaryDirectory() + "calltap-diag")
case "bridge":
    runBridge()
case "record":
    guard args.count > 1 else { print("использование: CallTap record <файл.wav>"); exit(2) }
    runRecord(path: args[1])
default:
    print("использование: CallTap record <файл.wav> | bridge | procs | diag <секунд> <папка>"); exit(2)
}
dispatchMain()
