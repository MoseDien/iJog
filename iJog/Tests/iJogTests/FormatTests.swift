import CoreLocation
import Testing
@testable import iJog

@Test func haversineKnownDistances() {
  // 赤道上经度 1° ≈ 111.19 km（R = 6371 km）
  let equatorOneDegree = haversine(
    CLLocationCoordinate2D(latitude: 0, longitude: 0),
    CLLocationCoordinate2D(latitude: 0, longitude: 1)
  )
  #expect(abs(equatorOneDegree - 111_195) < 1_000)

  // 赤道到北极 ≈ 1/4 周长 ≈ 10_007.5 km
  let quarterMeridian = haversine(
    CLLocationCoordinate2D(latitude: 0, longitude: 0),
    CLLocationCoordinate2D(latitude: 90, longitude: 0)
  )
  #expect(abs(quarterMeridian - 10_007_543) < 10_000)

  // 同一点距离为 0
  let samePoint = haversine(
    CLLocationCoordinate2D(latitude: 39.9, longitude: 116.4),
    CLLocationCoordinate2D(latitude: 39.9, longitude: 116.4)
  )
  #expect(samePoint == 0)
}

@Test func durationFormatting() {
  #expect(formatDuration(0) == "0:00:00")
  #expect(formatDuration(59.4) == "0:01:00") // 向上取整
  #expect(formatDuration(3661) == "1:01:01")
}

/// 距离/配速文案随系统语言本地化，测试用同一模板推导期望值（验证数值替换逻辑）
private func localizedDistance(_ km: Double) -> String {
  String(format: String(localized: "%.2f km"), km)
}

private func localizedPace(_ minutes: Int, _ seconds: Int) -> String {
  String(format: String(localized: "%d'%02d\"/km"), minutes, seconds)
}

@Test func distanceFormatting() {
  #expect(formatDistance(1500) == localizedDistance(1.5))
  #expect(formatDistance(0) == localizedDistance(0))
  #expect(formatDistance(42195) == localizedDistance(42.195))
}

@Test func paceFormatting() {
  #expect(formatPace(duration: 360, distance: 1000) == localizedPace(6, 0))
  #expect(formatPace(duration: 390, distance: 1000) == localizedPace(6, 30))
  #expect(formatPace(duration: 360, distance: 0) == "--")
  #expect(formatPace(duration: 360, distance: 0.5) == "--") // 不足 1 米
}
