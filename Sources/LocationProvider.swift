import Foundation
import CoreLocation

/// 定位 + 反向地理编码，给视频水印提供「位置」与「经纬度」。
/// 主线程写、采集队列读，快照用锁保护。
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let lock = NSLock()
    private var coordinate: CLLocationCoordinate2D?
    private var placeName: String?
    private var statusText = "定位中…"
    private var lastGeocoded: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            setStatus("定位权限被拒绝")
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            manager.startUpdatingLocation()
        default:
            manager.startUpdatingLocation()
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        geocoder.cancelGeocode()
    }

    /// 水印用的当前文本：(位置, 经纬度)。
    func snapshot() -> (place: String, coordinate: String) {
        lock.lock(); defer { lock.unlock() }
        guard let c = coordinate else { return (statusText, statusText) }
        return (placeName ?? "解析中…", String(format: "%.5f, %.5f", c.latitude, c.longitude))
    }

    private func setStatus(_ text: String) {
        lock.lock(); statusText = text; lock.unlock()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted: setStatus("定位权限被拒绝")
        case .authorizedAlways, .authorized: manager.startUpdatingLocation()
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lock.lock(); coordinate = loc.coordinate; lock.unlock()

        // 移动超过 100 米或尚未解析过才重新反查，避免频繁请求地理编码服务。
        if let last = lastGeocoded, loc.distance(from: last) < 100, placeName != nil { return }
        guard !geocoder.isGeocoding else { return }
        lastGeocoded = loc
        geocoder.reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "zh_CN")) { [weak self] marks, _ in
            guard let self, let m = marks?.first else { return }
            let parts = [m.administrativeArea, m.locality, m.subLocality, m.thoroughfare, m.name]
            var seen = Set<String>()
            let text = parts.compactMap { $0 }.filter { seen.insert($0).inserted }.joined()
            self.lock.lock()
            self.placeName = text.isEmpty ? nil : text
            self.lock.unlock()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied { setStatus("定位权限被拒绝") }
        else { setStatus("定位失败") }
    }
}
