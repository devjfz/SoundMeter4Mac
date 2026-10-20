import SwiftUI

struct CameraSection: View {
    @ObservedObject var camera: CameraRecorder
    /// 是否已点「开始」进入监测（自动模式下摄像头未开时用于展示阈值提示）。
    var isMonitoring: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("摄像头").font(.headline)
                Spacer()
                if camera.isRecording {
                    Label("录制中 \(timeString(camera.recordedSeconds))", systemImage: "record.circle")
                        .foregroundStyle(.red)
                        .monospacedDigit()
                }
            }

            preview

            HStack(spacing: 12) {
                Text("画面已叠加时间与 dB(A)/dB(C)，录制文件与预览一致")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("更改保存目录") { camera.chooseOutputDirectory() }
                Button("在 Finder 中显示") { camera.revealLastFile() }
                    .disabled(camera.lastSavedURL == nil)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("保存目录：\(camera.outputDirectory.path)")
                if let url = camera.lastSavedURL {
                    Text("最近保存：\(url.lastPathComponent)")
                }
                if !camera.triggerEvents.isEmpty {
                    Text("最近自动触发：")
                    ForEach(camera.triggerEvents.prefix(5)) { event in
                        Text(String(format: "  %@  触发值 %.1f dB(C) ≥ 阈值 %.0f",
                                    timeFormatter.string(from: event.date), event.dbC, event.threshold))
                            .monospacedDigit()
                    }
                }
                if let message = camera.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.85))
            if let image = camera.previewImage {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if isMonitoring && camera.mode == .auto && !camera.isPreviewing {
                // 自动模式已开始监测但环境音尚未达标：中间给出明确阈值提示。
                Text(String(format: "未达到设定的 %.0f dB(C) 阈值", camera.threshold))
                    .font(.title3)
                    .foregroundStyle(.orange)
            } else {
                Text(placeholderText)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 260)
    }

    private var placeholderText: String {
        if camera.isPreviewing { return "等待画面…" }
        return camera.mode == .auto
            ? "自动模式：环境 dB(C) 达到阈值后自动开启摄像头录制"
            : "点击「开始」同时采集音频与视频"
    }

    private func timeString(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
