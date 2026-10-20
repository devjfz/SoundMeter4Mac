import Foundation
import AVFoundation
import Accelerate

struct Reading: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let dbA: Double
    let dbC: Double
    let dbZ: Double

    func value(for w: Weighting) -> Double {
        switch w {
        case .a: return dbA
        case .c: return dbC
        case .z: return dbZ
        }
    }
}

/// A/C 计权的累计统计（最小、等效平均 Leq、最大），用于烧进视频画面。
struct LevelStats {
    let minA: Double, avgA: Double, maxA: Double
    let minC: Double, avgC: Double, maxC: Double
}

/// 麦克风采集 + A/C/Z 计权，每秒输出一条 Leq(1s) 记录。
@MainActor
final class AudioMeter: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var readings: [Reading] = []
    @Published private(set) var latest: Reading?
    @Published private(set) var errorMessage: String?
    /// 校准偏移：dB SPL = dBFS + offset。用已知声级的参考源校准。
    @Published var calibrationOffset: Double = UserDefaults.standard.object(forKey: "calibrationOffset") as? Double ?? 94.0 {
        didSet { UserDefaults.standard.set(calibrationOffset, forKey: "calibrationOffset") }
    }

    /// 每产出一条记录时回调，用于把实时分贝值送去合成到视频画面。
    var onReading: ((Reading) -> Void)?

    private let engine = AVAudioEngine()
    private let fftSize = 8192
    private let hopSize = 4096
    private var fftSetup: FFTSetup?
    private var hann = [Float]()
    private var gains: [Weighting: [Double]] = [:]
    private var sampleRate: Double = 48000

    private var pending = [Float]()           // 未处理的输入样本
    private var energy: [Weighting: Double] = [:]  // 本秒累计的计权均方值
    private var blocks = 0
    private var samplesThisSecond = 0

    init() {
        let log2n = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    func start() {
        guard !isRunning else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.errorMessage = "麦克风权限被拒绝，请在「系统设置 → 隐私与安全性 → 麦克风」中开启。"
                    return
                }
                self.beginCapture()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        resetAccumulators()
    }

    func clear() {
        readings.removeAll()
        latest = nil
    }

    /// 基于当前所有记录计算 A/C 的最小、等效平均(Leq)、最大；无数据时返回 nil。
    /// 与界面统计面板口径一致（平均用能量平均 Leq，而非算术平均）。
    func levelStats() -> LevelStats? {
        guard !readings.isEmpty else { return nil }
        let a = readings.map(\.dbA)
        let c = readings.map(\.dbC)
        func leq(_ values: [Double]) -> Double {
            let usable = values.filter { $0 > -150 }
            guard !usable.isEmpty else { return -200 }
            let mean = usable.reduce(0) { $0 + pow(10, $1 / 10) } / Double(usable.count)
            return 10 * log10(mean)
        }
        return LevelStats(minA: a.min() ?? 0, avgA: leq(a), maxA: a.max() ?? 0,
                          minC: c.min() ?? 0, avgC: leq(c), maxC: c.max() ?? 0)
    }

    private func beginCapture() {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorMessage = "未找到可用的音频输入设备。"
            return
        }
        prepare(sampleRate: format.sampleRate)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            Task { @MainActor in self?.consume(samples) }
        }

        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            errorMessage = nil
        } catch {
            errorMessage = "启动音频引擎失败：\(error.localizedDescription)"
        }
    }

    /// 按输入设备采样率预计算计权表并复位累加器。
    func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        gains = Dictionary(uniqueKeysWithValues: Weighting.allCases.map {
            ($0, $0.powerGains(fftSize: fftSize, sampleRate: sampleRate))
        })
        resetAccumulators()
    }

    private func resetAccumulators() {
        pending.removeAll(keepingCapacity: true)
        energy = Dictionary(uniqueKeysWithValues: Weighting.allCases.map { ($0, 0.0) })
        blocks = 0
        samplesThisSecond = 0
    }

    /// 消费输入样本；累计满 1 秒即产出一条记录。
    func consume(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        samplesThisSecond += samples.count

        while pending.count >= fftSize {
            analyze(block: Array(pending[0..<fftSize]))
            pending.removeFirst(hopSize)
        }

        if samplesThisSecond >= Int(sampleRate), blocks > 0 {
            emitReading()
        }
    }

    private func emitReading() {
        func level(_ w: Weighting) -> Double {
            let meanSquare = (energy[w] ?? 0) / Double(blocks)
            guard meanSquare > 0 else { return -200 }
            return 10 * log10(meanSquare) + calibrationOffset
        }
        let reading = Reading(date: Date(), dbA: level(.a), dbC: level(.c), dbZ: level(.z))
        latest = reading
        readings.append(reading)
        onReading?(reading)

        energy = Dictionary(uniqueKeysWithValues: Weighting.allCases.map { ($0, 0.0) })
        blocks = 0
        samplesThisSecond = 0
    }

    /// 对一个 FFT 块做频域计权，把三种计权的均方值累加到本秒的累加器。
    private func analyze(block raw: [Float]) {
        guard let fftSetup, let ga = gains[.a], let gc = gains[.c], let gz = gains[.z] else { return }
        let n = fftSize
        let half = n / 2

        // 未加窗信号的均方值，用于把频谱能量归一化回真实量级（Parseval 校正，顺带消掉窗函数增益）。
        var trueMeanSquare: Float = 0
        vDSP_measqv(raw, 1, &trueMeanSquare, vDSP_Length(n))
        guard trueMeanSquare > 0 else { return }

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(raw, 1, hann, 1, &windowed, 1, vDSP_Length(n))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        var nyquistPower: Float = 0

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, vDSP_Length(log2(Double(n))), FFTDirection(FFT_FORWARD))
                // zrip 的打包约定：DC 在 realp[0]，Nyquist 在 imagp[0]
                let dc = rp[0]
                let nyq = ip[0]
                rp[0] = 0
                ip[0] = 0
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                power[0] = dc * dc
                nyquistPower = nyq * nyq
            }
        }

        var unweighted = 0.0, ea = 0.0, ec = 0.0, ez = 0.0
        for bin in 0..<half {
            let p = Double(power[bin]) * (bin == 0 ? 1 : 2)
            unweighted += p
            ea += p * ga[bin]
            ec += p * gc[bin]
            ez += p * gz[bin]
        }
        let pn = Double(nyquistPower)
        unweighted += pn
        ea += pn * ga[half]
        ec += pn * gc[half]
        ez += pn * gz[half]

        guard unweighted > 0 else { return }
        let scale = Double(trueMeanSquare) / unweighted
        energy[.a, default: 0] += ea * scale
        energy[.c, default: 0] += ec * scale
        energy[.z, default: 0] += ez * scale
        blocks += 1
    }
}
