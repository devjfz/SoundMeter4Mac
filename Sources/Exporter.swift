import Foundation
import AppKit
import UniformTypeIdentifiers

enum Exporter {
    /// 导出为 Excel 可直接双击打开的 CSV（UTF-8 BOM + 本地时间列）。
    static func exportCSV(_ readings: [Reading], calibrationOffset: Double) {
        guard !readings.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.nameFieldStringValue = defaultFileName()
        panel.title = "导出分贝记录"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var csv = "\u{FEFF}"  // BOM，避免 Excel 打开中文表头乱码
        csv += "时间,dB(A),dB(C),dB(Z),校准偏移\n"
        for r in readings {
            csv += "\(formatter.string(from: r.date)),"
            csv += String(format: "%.1f,%.1f,%.1f,%.1f\n", r.dbA, r.dbC, r.dbZ, calibrationOffset)
        }

        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "导出失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private static func defaultFileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "分贝记录-\(f.string(from: Date())).csv"
    }
}
