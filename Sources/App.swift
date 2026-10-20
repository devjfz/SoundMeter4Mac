import SwiftUI
import Charts

@main
struct AudioCatcherApp: App {
    @StateObject private var meter = AudioMeter()
    @StateObject private var camera = CameraRecorder()

    var body: some Scene {
        WindowGroup("声音分贝记录仪") {
            ContentView(meter: meter, camera: camera)
                .frame(minWidth: 760, minHeight: 620)
                .onAppear {
                    // 分贝值实时送去合成到视频画面（含累计最小/平均/最大统计）
                    meter.onReading = { [weak meter, weak camera] reading in
                        camera?.updateLevels(dbA: reading.dbA, dbC: reading.dbC,
                                             stats: meter?.levelStats())
                    }
                }
        }
    }
}

struct ChartPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
    let series: String
}

struct ContentView: View {
    @ObservedObject var meter: AudioMeter
    @ObservedObject var camera: CameraRecorder
    @State private var windowSeconds = 120

    private var recent: [Reading] { Array(meter.readings.suffix(windowSeconds)) }

    private var points: [ChartPoint] {
        recent.flatMap {
            [ChartPoint(date: $0.date, value: $0.dbA, series: "dB(A)"),
             ChartPoint(date: $0.date, value: $0.dbC, series: "dB(C)")]
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                chart
                statsRow
                controls
                if let message = meter.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
                Divider()
                CameraSection(camera: camera, isMonitoring: isCapturing)
            }
            .padding(20)
        }
    }

    private var isCapturing: Bool { meter.isRunning || camera.isPreviewing }

    private var statusText: String {
        guard isCapturing else { return "已停止" }
        return camera.isRecording ? "采集中 · 正在录制视频" : "监测中 · 未录制"
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline, spacing: 32) {
            bigReadout("dB(A)", meter.latest?.dbA)
            bigReadout("dB(C)", meter.latest?.dbC)
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(isCapturing ? (camera.isRecording ? .red : .green) : .secondary)
                Text("已记录 \(meter.readings.count) 条").font(.caption).foregroundStyle(.secondary)
                readout("dB(Z)", meter.latest?.dbZ)
            }
        }
    }

    private func bigReadout(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("当前 \(title)").font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.1f", $0) } ?? "--")
                .font(.system(size: 52, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    private func readout(_ title: String, _ value: Double?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.1f", $0) } ?? "--")
                .font(.title3).monospacedDigit()
        }
    }

    private var chart: some View {
        Chart(points) { point in
            LineMark(
                x: .value("时间", point.date),
                y: .value("分贝", point.value)
            )
            .foregroundStyle(by: .value("计权", point.series))
            .interpolationMethod(.monotone)
        }
        .chartYScale(domain: yDomain)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
        .chartLegend(position: .top, alignment: .trailing)
        .frame(minHeight: 240)
        .overlay {
            if points.isEmpty {
                Text("点击「开始」后，曲线每秒更新一次")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statsRow: some View {
        let a = meter.readings.map(\.dbA)
        let c = meter.readings.map(\.dbC)
        return HStack(alignment: .top, spacing: 28) {
            // GridRow 直接内联，避免包装成函数后 Grid 认不出行结构。
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("dB(A)").font(.caption).foregroundStyle(.secondary)
                    Text("dB(C)").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("当前").font(.caption).foregroundStyle(.secondary)
                    Text(fmt(meter.latest?.dbA)).monospacedDigit().bold()
                    Text(fmt(meter.latest?.dbC)).monospacedDigit().bold()
                }
                GridRow {
                    Text("Leq").font(.caption).foregroundStyle(.secondary)
                    Text(fmt(leq(a))).monospacedDigit()
                    Text(fmt(leq(c))).monospacedDigit()
                }
                GridRow {
                    Text("最小").font(.caption).foregroundStyle(.secondary)
                    Text(fmt(a.min())).monospacedDigit()
                    Text(fmt(c.min())).monospacedDigit()
                }
                GridRow {
                    Text("最大").font(.caption).foregroundStyle(.secondary)
                    Text(fmt(a.max())).monospacedDigit()
                    Text(fmt(c.max())).monospacedDigit()
                }
            }
            Spacer()
            Picker("曲线窗口", selection: $windowSeconds) {
                Text("1 分钟").tag(60)
                Text("2 分钟").tag(120)
                Text("10 分钟").tag(600)
                Text("全部").tag(Int.max)
            }
            .frame(width: 200)
        }
    }

    private func fmt(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "--"
    }

    /// 等效连续声级：能量平均而非算术平均。
    private func leq(_ values: [Double]) -> Double? {
        let usable = values.filter { $0 > -150 }
        guard !usable.isEmpty else { return nil }
        let mean = usable.reduce(0) { $0 + pow(10, $1 / 10) } / Double(usable.count)
        return 10 * log10(mean)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button(isCapturing ? "停止" : "开始") {
                    if isCapturing {
                        meter.stop()
                        camera.stopCapture()
                        camera.stopLocation()
                    } else {
                        meter.start()
                        camera.startLocation()
                        // 自动模式先只做音频监测，dB(C) 达到阈值再启动摄像头；手动模式立即开录。
                        if camera.mode == .manual { camera.startCapture() }
                    }
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("清空记录") { meter.clear() }
                    .disabled(meter.readings.isEmpty)

                Button("导出 CSV（Excel 可打开）") {
                    Exporter.exportCSV(meter.readings, calibrationOffset: meter.calibrationOffset)
                }
                .disabled(meter.readings.isEmpty)

                Spacer()

                HStack(spacing: 6) {
                    Text("校准偏移").font(.caption).foregroundStyle(.secondary)
                    Stepper(value: $meter.calibrationOffset, in: 0...140, step: 0.5) {
                        Text(String(format: "%.1f dB", meter.calibrationOffset)).monospacedDigit()
                    }
                    .frame(width: 130)
                }
            }

            HStack(spacing: 12) {
                Picker("模式", selection: $camera.mode) {
                    ForEach(CaptureMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .disabled(isCapturing)

                Picker("水印权重", selection: $camera.weighting) {
                    Text("C").tag(Weighting.c)
                    Text("A").tag(Weighting.a)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)

                if camera.mode == .auto {
                    HStack(spacing: 6) {
                        Text("触发阈值").font(.caption).foregroundStyle(.secondary)
                        Stepper(value: $camera.threshold, in: 20...130, step: 1) {
                            Text(String(format: "%.0f dB(C)", camera.threshold)).monospacedDigit()
                        }
                        .frame(width: 150)
                    }
                    HStack(spacing: 6) {
                        Text("单段时长").font(.caption).foregroundStyle(.secondary)
                        Stepper(value: $camera.segmentMinutes, in: 0.5...30, step: 0.5) {
                            Text(String(format: "%.1f 分钟", camera.segmentMinutes)).monospacedDigit()
                        }
                        .frame(width: 150)
                    }
                    HStack(spacing: 6) {
                        Text("持续超阈值").font(.caption).foregroundStyle(.secondary)
                        Stepper(value: $camera.holdSeconds, in: 1...30, step: 1) {
                            Text(String(format: "%.0f 秒", camera.holdSeconds)).monospacedDigit()
                        }
                        .frame(width: 130)
                    }
                }
                Spacer()
                Text(modeHint).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var modeHint: String {
        switch camera.mode {
        case .manual:
            return "手动模式：点「开始」立即录制"
        case .auto:
            if !isCapturing { return "自动模式：点「开始」后仅音频监测，dB(C) 达到阈值才启动摄像头录制" }
            if camera.isRecording {
                let left = max(0, Int(camera.segmentMinutes * 60) - camera.recordedSeconds)
                return "录制中 · 剩余 \(left / 60):\(String(format: "%02d", left % 60)) · 已触发 \(camera.autoTriggerCount) 次"
            }
            return "监测中（摄像头待命）· 连续达标 \(camera.secondsAboveThreshold)/\(Int(camera.holdSeconds)) 秒 · 已触发 \(camera.autoTriggerCount) 次"
        }
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.value).filter { $0 > -150 }
        guard let lo = values.min(), let hi = values.max() else { return 0...100 }
        let pad = max(3, (hi - lo) * 0.15)
        return (lo - pad)...(hi + pad)
    }
}
