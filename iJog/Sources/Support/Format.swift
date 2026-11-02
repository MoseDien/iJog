import CoreLocation
import Foundation

/// Haversine 大圆距离（米）
func haversine(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
  let radius = 6_371_000.0 // 地球平均半径（米）
  let dLat = (b.latitude - a.latitude) * .pi / 180
  let dLon = (b.longitude - a.longitude) * .pi / 180
  let latA = a.latitude * .pi / 180
  let latB = b.latitude * .pi / 180
  let h = sin(dLat / 2) * sin(dLat / 2) + cos(latA) * cos(latB) * sin(dLon / 2) * sin(dLon / 2)
  return 2 * radius * asin(min(1, sqrt(h)))
}

/// 不足 1 小时显示 mm:ss，满 1 小时显示 h:mm:ss（向上取整到秒，避免跑步中长时间显示 00:00）
func formatDuration(_ interval: TimeInterval) -> String {
  let seconds = Int(interval.rounded(.up))
  if seconds >= 3600 {
    return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
  }
  return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

/// x.xx 公里 / x.xx km
func formatDistance(_ meters: Double) -> String {
  String(format: String(localized: "%.2f km"), meters / 1000)
}

/// x'xx"/公里（km），距离不足 1 米时显示 "--"
func formatPace(duration: TimeInterval, distance meters: Double) -> String {
  guard meters >= 1 else { return "--" }
  let secondsPerKm = duration / (meters / 1000)
  let minutes = Int(secondsPerKm) / 60
  let seconds = Int(secondsPerKm) % 60
  return String(format: String(localized: "%d'%02d\"/km"), minutes, seconds)
}
