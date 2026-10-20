import Foundation

/// IEC 61672-1 频率计权。
enum Weighting: String, CaseIterable, Identifiable {
    case a = "A"
    case c = "C"
    case z = "Z"

    var id: String { rawValue }
    var label: String { "dB(\(rawValue))" }

    /// 指定频率处的计权增益（dB）。
    func gainDB(atHz f: Double) -> Double {
        guard f > 0 else { return -200 }
        let f2 = f * f
        let f4 = f2 * f2
        switch self {
        case .a:
            let num = 12194.0 * 12194.0 * f4
            let den = (f2 + 20.6 * 20.6)
                * sqrt((f2 + 107.7 * 107.7) * (f2 + 737.9 * 737.9))
                * (f2 + 12194.0 * 12194.0)
            return 20 * log10(num / den) + 2.00
        case .c:
            let num = 12194.0 * 12194.0 * f2
            let den = (f2 + 20.6 * 20.6) * (f2 + 12194.0 * 12194.0)
            return 20 * log10(num / den) + 0.06
        case .z:
            return 0
        }
    }

    /// 预计算每个 FFT 频点的功率增益（10^(dB/10)），bin 数为 fftSize/2 + 1。
    func powerGains(fftSize: Int, sampleRate: Double) -> [Double] {
        let binCount = fftSize / 2 + 1
        let df = sampleRate / Double(fftSize)
        return (0..<binCount).map { bin in
            // 20 Hz 以下、Nyquist 附近的能量对听感无意义，直接压掉避免直流偏置污染 Z 计权。
            let f = Double(bin) * df
            guard f >= 10 else { return 0 }
            return pow(10, gainDB(atHz: f) / 10)
        }
    }
}
