import Foundation
import AVFoundation
import CoreImage
import CoreText
import QuartzCore
import AppKit

/// 采集模式：手动=点开始就录；自动=点开始只监测，超阈值自动录一段。
enum CaptureMode: String, CaseIterable, Identifiable {
    case manual = "手动"
    case auto = "自动"
    var id: String { rawValue }
}

/// 摄像头采集：把实时时间烧进画面，编码为 mp4。
final class CameraRecorder: NSObject, ObservableObject {
    @Published private(set) var isPreviewing = false
    @Published private(set) var isRecording = false
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSavedURL: URL?
    @Published private(set) var recordedSeconds: Int = 0
    /// 自动触发计数，便于确认自动模式确实工作过。
    @Published private(set) var autoTriggerCount = 0
    /// 最近的自动触发记录（含触发时的实际分贝值），用于核对"为什么开始了"。
    @Published private(set) var triggerEvents: [TriggerEvent] = []
    /// 上一秒的分贝读数与连续超阈值秒数，用于判断触发条件。
    @Published private(set) var secondsAboveThreshold = 0

    struct TriggerEvent: Identifiable {
        let id = UUID()
        let date: Date
        let dbC: Double
        let threshold: Double
    }

    /// 需要连续超过阈值多少秒才触发，避免单次瞬态（关门、敲键盘）误触发。
    @Published var holdSeconds: Double = UserDefaults.standard.object(forKey: "holdSeconds") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(holdSeconds, forKey: "holdSeconds") }
    }

    @Published var mode: CaptureMode = {
        guard let raw = UserDefaults.standard.string(forKey: "captureMode") else { return .manual }
        return CaptureMode(rawValue: raw) ?? .manual
    }() {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "captureMode") }
    }

    /// 自动模式触发阈值，单位 dB(C)。
    @Published var threshold: Double = UserDefaults.standard.object(forKey: "autoThreshold") as? Double ?? 70 {
        didSet { UserDefaults.standard.set(threshold, forKey: "autoThreshold") }
    }

    /// 自动模式单段录制时长（分钟）。
    @Published var segmentMinutes: Double = UserDefaults.standard.object(forKey: "segmentMinutes") as? Double ?? 3 {
        didSet { UserDefaults.standard.set(segmentMinutes, forKey: "segmentMinutes") }
    }

    /// 视频保存目录，默认 ~/Downloads。
    @Published var outputDirectory: URL = {
        if let saved = UserDefaults.standard.url(forKey: "outputDirectory") { return saved }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }() {
        didSet { UserDefaults.standard.set(outputDirectory, forKey: "outputDirectory") }
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "camera.capture")

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var audioFormat: CMFormatDescription?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var lastReportedSecond = -1
    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var sessionStarted = false
    private var startPTS: CMTime = .zero
    private var lastPreviewTime: CFTimeInterval = 0
    /// 以下两个只在 queue 上访问，避免和主线程的 @Published 状态竞争。
    private var recordingFlag = false
    private var pendingURL: URL?
    private var framesWaitingForAudio = 0
    /// 自动模式启动摄像头到开始录制之间的去重标志，避免预览预热期间重复触发。
    private var autoArming = false
    /// 定位与反向地理编码，供水印显示位置/经纬度。
    private let location = LocationProvider()
    /// 最近一帧的时间戳（仅采集队列访问），用于水印上的当前录制时长。
    private var lastFramePTS: CMTime = .zero

    func startLocation() { location.start() }
    func stopLocation() { location.stop() }

    private let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    // MARK: - 采集控制

    /// 开启摄像头；手动模式立即开录，自动模式只做监测等待触发。
    func startCapture() {
        guard !isPreviewing else { return }
        startPreview { [weak self] in
            guard let self else { return }
            if self.mode == .manual { self.startRecording() }
        }
    }

    func stopCapture() {
        stopRecording()
        stopPreview()
    }

    func startPreview(completion: (() -> Void)? = nil) {
        guard !isPreviewing else { return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else {
                DispatchQueue.main.async {
                    self?.errorMessage = "摄像头权限被拒绝，请在「系统设置 → 隐私与安全性 → 摄像头」中开启。"
                }
                return
            }
            // 视频要带声音，麦克风权限也要拿到；被拒时仍然继续，只是录不到音轨。
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.errorMessage = micGranted ? nil : "麦克风权限被拒绝，视频将没有声音。"
                    self.configureAndRun()
                    if self.isPreviewing { completion?() }
                }
            }
        }
    }

    func stopPreview() {
        if isRecording { stopRecording() }
        autoArming = false
        guard isPreviewing else { return }
        session.stopRunning()
        isPreviewing = false
        previewImage = nil
    }

    private func configureAndRun() {
        if session.inputs.isEmpty {
            session.beginConfiguration()
            session.sessionPreset = .high
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                errorMessage = "未找到可用的摄像头。"
                return
            }
            session.addInput(input)
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }

            // 音轨：和视频共用同一条串行队列，避免 writer 状态被两路回调同时改写。
            if let mic = AVCaptureDevice.default(for: .audio),
               let micInput = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(micInput) {
                session.addInput(micInput)
                audioOutput.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
            } else {
                errorMessage = "未找到可用的麦克风，视频将没有声音。"
            }
            session.commitConfiguration()
        }
        queue.async { [weak self] in self?.session.startRunning() }
        isPreviewing = true
    }

    // MARK: - 录制控制

    func startRecording() {
        guard !isRecording else { return }
        let url = makeOutputURL()
        queue.async { [weak self] in
            self?.sessionStarted = false
            self?.pendingURL = url
            self?.framesWaitingForAudio = 0
            self?.recordingFlag = true
        }
        isRecording = true
        recordedSeconds = 0
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        queue.async { [weak self] in
            guard let self else { return }
            self.recordingFlag = false
            guard let writer = self.writer, let input = self.writerInput else { return }
            input.markAsFinished()
            self.audioWriterInput?.markAsFinished()
            let url = writer.outputURL
            writer.finishWriting {
                DispatchQueue.main.async {
                    if writer.status == .completed {
                        self.lastSavedURL = url
                    } else {
                        self.errorMessage = "写入视频失败：\(writer.error?.localizedDescription ?? "未知错误")"
                    }
                }
            }
            self.writer = nil
            self.writerInput = nil
            self.audioWriterInput = nil
            self.adaptor = nil
            self.sessionStarted = false
        }
    }

    func revealLastFile() {
        guard let url = lastSavedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory
        panel.prompt = "选择"
        panel.title = "选择视频保存目录"
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
        }
    }

    /// 叠加用的实时分贝值与累计统计。主线程写、采集队列读，用锁保护。
    private let levelLock = NSLock()
    private var overlayLevels: (a: Double, c: Double)?
    private var overlayStats: LevelStats?
    /// 水印使用的权重，主线程写、采集队列读，随 levelLock 同步。
    private var overlayWeighting: Weighting =
        Weighting(rawValue: UserDefaults.standard.string(forKey: "overlayWeighting") ?? "C") ?? .c

    /// 水印显示的权重（A 或 C），默认 C。
    @Published var weighting: Weighting = {
        Weighting(rawValue: UserDefaults.standard.string(forKey: "overlayWeighting") ?? "C") ?? .c
    }() {
        didSet {
            UserDefaults.standard.set(weighting.rawValue, forKey: "overlayWeighting")
            levelLock.lock(); overlayWeighting = weighting; levelLock.unlock()
        }
    }

    /// 自动模式的触发判定抽成纯函数，便于离线校验真值表。
    /// 以 dB(C) 与阈值比较；secondsAbove 为「已连续达到阈值的秒数」，需 >= holdSeconds 才触发。
    /// 不要求摄像头已开启：自动模式下摄像头默认关闭，达到阈值时才启动采集。
    static func shouldAutoStart(mode: CaptureMode, recording: Bool,
                                dbC: Double, threshold: Double,
                                secondsAbove: Int, holdSeconds: Double) -> Bool {
        guard mode == .auto, !recording else { return false }
        guard dbC >= threshold else { return false }
        return secondsAbove >= max(1, Int(holdSeconds.rounded()))
    }

    static func shouldAutoStop(mode: CaptureMode, elapsed: Int, segmentMinutes: Double) -> Bool {
        mode == .auto && elapsed >= Int(segmentMinutes * 60)
    }

    func updateLevels(dbA: Double, dbC: Double, stats: LevelStats? = nil) {
        levelLock.lock()
        overlayLevels = (dbA, dbC)
        overlayStats = stats
        levelLock.unlock()

        // 连续达到阈值计数（按 dB(C)）：低于阈值立刻归零
        secondsAboveThreshold = dbC >= threshold ? secondsAboveThreshold + 1 : 0

        // 自动模式：环境噪音（dB(C)）连续达到阈值就启动采集并录一段（已在录制中则忽略）。
        if Self.shouldAutoStart(mode: mode, recording: isRecording,
                                dbC: dbC, threshold: threshold,
                                secondsAbove: secondsAboveThreshold, holdSeconds: holdSeconds) {
            autoTriggerCount += 1
            triggerEvents.insert(TriggerEvent(date: Date(), dbC: dbC, threshold: threshold), at: 0)
            if triggerEvents.count > 10 { triggerEvents.removeLast() }
            autoStart()
        }
    }

    /// 达到阈值时的自动采集：摄像头未开启则先启动预览，就绪后立即开始录制。
    private func autoStart() {
        guard !autoArming else { return }
        if isPreviewing {
            startRecording()
        } else {
            autoArming = true
            startPreview { [weak self] in
                self?.startRecording()
                self?.autoArming = false
            }
        }
    }

    private var overlayLines: [String] {
        // recordingFlag 是采集队列侧的状态，和 drawOverlay 同线程，读它不会有竞争。
        let status = recordingFlag ? "[REC]" : "[监测]"
        levelLock.lock()
        let levels = overlayLevels
        let stats = overlayStats
        let useC = overlayWeighting == .c
        levelLock.unlock()
        let loc = location.snapshot()

        // 水印只显示当前选中的一种权重（A 或 C）。
        func val(_ c: Double?, _ a: Double?) -> String {
            (useC ? c : a).map { String(format: "%.1f", $0) } ?? "--"
        }
        var elapsed = 0
        if recordingFlag && sessionStarted {
            elapsed = max(0, Int(CMTimeGetSeconds(CMTimeSubtract(lastFramePTS, startPTS))))
        }
        return [
            "时间: \(stampFormatter.string(from: Date()))  \(status)",
            "位置: \(loc.place)",
            "经纬度: \(loc.coordinate)",
            "权重: \(useC ? "C" : "A")",
            "最大分贝: \(val(stats?.maxC, stats?.maxA))",
            "最小分贝: \(val(stats?.minC, stats?.minA))",
            "当前分贝: \(val(levels?.c, levels?.a))",
            String(format: "当前录制时长: %02d:%02d:%02d", elapsed / 3600, elapsed % 3600 / 60, elapsed % 60)
        ]
    }

    private func makeOutputURL() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return outputDirectory.appendingPathComponent("摄像头录制-\(f.string(from: Date())).mp4")
    }
}

// MARK: - 帧处理

extension CameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            processAudio(sampleBuffer)
        } else {
            process(sampleBuffer)
        }
    }

    /// 音频帧：只在视频轨已经开写之后才追加，保证两轨起点一致。
    func processAudio(_ sampleBuffer: CMSampleBuffer) {
        if audioFormat == nil {
            audioFormat = CMSampleBufferGetFormatDescription(sampleBuffer)
        }
        guard recordingFlag, sessionStarted,
              let input = audioWriterInput, input.isReadyForMoreMediaData,
              CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= startPTS else { return }
        input.append(sampleBuffer)
    }

    /// 单帧处理入口（与采集回调解耦，便于离线灌帧验证）。
    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        lastFramePTS = pts

        // 直接在像素缓冲上绘制水印（时间、位置、经纬度、分贝）：预览和录制文件用的是同一份已烧字的画面。
        drawOverlay(on: pixelBuffer)

        if recordingFlag {
            appendFrame(pixelBuffer, pts: pts)
        }
        publishPreview(pixelBuffer)
    }

    func drawOverlay(on pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let ctx = CGContext(data: base,
                                 width: width,
                                 height: height,
                                 bitsPerComponent: 8,
                                 bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        // 缓冲区首行是画面顶部，CGContext 原点在左下，所以翻转 CTM 并同步翻转文字矩阵。
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        let fontSize = max(16, CGFloat(height) / 24)
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        ]
        let lines = overlayLines.map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attrs))
        }
        guard !lines.isEmpty else { return }

        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let widths = lines.map { line -> CGFloat in
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
            ascent = max(ascent, a); descent = max(descent, d); leading = max(leading, l)
            return w
        }

        // 翻转后的坐标系里 y 向下增长，(boxX, boxY) 就是画面左上角。
        let pad = fontSize * 0.3
        let boxX = fontSize * 0.5
        let boxY = fontSize * 0.5
        let lineHeight = ascent + descent + leading
        let boxHeight = lineHeight * CGFloat(lines.count) + pad * 2

        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        ctx.fill(CGRect(x: boxX, y: boxY,
                        width: (widths.max() ?? 0) + pad * 2,
                        height: boxHeight))

        for (i, line) in lines.enumerated() {
            ctx.textPosition = CGPoint(x: boxX + pad,
                                       y: boxY + pad + ascent + lineHeight * CGFloat(i))
            CTLineDraw(line, ctx)
        }
    }

    private func appendFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        if !sessionStarted {
            // 音频格式要等第一个音频帧才知道；短暂等待以免生成没有音轨的文件。
            if audioFormat == nil && framesWaitingForAudio < 15 {
                framesWaitingForAudio += 1
                return
            }
            guard let url = pendingURL else { return }
            do {
                try startWriting(url: url,
                                 width: CVPixelBufferGetWidth(pixelBuffer),
                                 height: CVPixelBufferGetHeight(pixelBuffer),
                                 pts: pts)
            } catch {
                recordingFlag = false
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.errorMessage = "创建视频文件失败：\(error.localizedDescription)"
                }
                return
            }
        }
        guard let input = writerInput, input.isReadyForMoreMediaData,
              let adaptor = adaptor else { return }
        adaptor.append(pixelBuffer, withPresentationTime: pts)

        let elapsed = Int(CMTimeGetSeconds(CMTimeSubtract(pts, startPTS)))
        if elapsed != lastReportedSecond {
            lastReportedSecond = elapsed
            DispatchQueue.main.async {
                self.recordedSeconds = elapsed
                // 自动模式：录满设定时长就收尾落盘，并关闭摄像头，回到纯音频监测。
                if Self.shouldAutoStop(mode: self.mode, elapsed: elapsed,
                                       segmentMinutes: self.segmentMinutes) {
                    self.stopRecording()
                    if self.mode == .auto { self.stopPreview() }
                }
            }
        }
    }

    private func startWriting(url: URL, width: Int, height: Int, pts: CMTime) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)

        // 音轨用 AAC 编码；采样率/声道数照抄输入设备的实际格式。
        if let fd = audioFormat,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame),
                AVSampleRateKey: asbd.mSampleRate,
                AVEncoderBitRateKey: 128_000
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio,
                                            outputSettings: audioSettings,
                                            sourceFormatHint: fd)
            aInput.expectsMediaDataInRealTime = true
            if writer.canAdd(aInput) {
                writer.add(aInput)
                audioWriterInput = aInput
            }
        }

        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: pts)

        self.writer = writer
        self.writerInput = input
        self.adaptor = adaptor
        self.startPTS = pts
        self.lastReportedSecond = -1
        self.sessionStarted = true
    }

    private func publishPreview(_ pixelBuffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastPreviewTime > 1.0 / 15 else { return }
        lastPreviewTime = now
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = CameraRecorder.ciContext.createCGImage(ci, from: ci.extent) else { return }
        DispatchQueue.main.async { self.previewImage = cg }
    }
}

