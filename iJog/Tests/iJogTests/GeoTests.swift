import CoreLocation
import Testing
@testable import iJog

@Test func chinaDetection() {
  #expect(isInMainlandChina(CLLocationCoordinate2D(latitude: 39.9, longitude: 116.4))) // 北京
  #expect(isInMainlandChina(CLLocationCoordinate2D(latitude: 31.2, longitude: 121.5))) // 上海
  #expect(!isInMainlandChina(CLLocationCoordinate2D(latitude: 37.33, longitude: -122.0))) // 库比蒂诺
  #expect(!isInMainlandChina(CLLocationCoordinate2D(latitude: 35.68, longitude: 139.76))) // 东京
}

@Test func displayCoordinateShiftsBeijingByPlausibleOffset() {
  // 中国境内：GCJ-02 偏移量通常在数百米量级（100m–1000m）
  let wgs = CLLocationCoordinate2D(latitude: 39.9075, longitude: 116.3912)
  let gcj = displayCoordinate(wgs)
  let offset = haversine(wgs, gcj)
  #expect(offset > 100)
  #expect(offset < 1000)
  // 偏移方向：偏东北（GCJ 相对 WGS 在中国普遍东移北移）
  #expect(gcj.latitude > wgs.latitude)
  #expect(gcj.longitude > wgs.longitude)
}

@Test func displayCoordinatePassesThroughOutsideChina() {
  let cupertino = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.009)
  let tokyo = CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671)
  let convertedCupertino = displayCoordinate(cupertino)
  let convertedTokyo = displayCoordinate(tokyo)
  #expect(convertedCupertino.latitude == cupertino.latitude)
  #expect(convertedCupertino.longitude == cupertino.longitude)
  #expect(convertedTokyo.latitude == tokyo.latitude)
  #expect(convertedTokyo.longitude == tokyo.longitude)
}

@Test func displayCoordinatesApplyToWholeRoute() {
  let route = [
    RoutePoint(lat: 39.9087, lon: 116.3975),
    RoutePoint(lat: 39.9092, lon: 116.3989),
    RoutePoint(lat: 0, lon: 0), // 境外点原样返回
  ]
  let display = route.displayCoordinates
  #expect(display.count == 3)
  #expect(display[0].latitude > route[0].lat) // 北京点被转换
  #expect(display[2].latitude == route[2].lat) // 境外点不变
}
