import CoreLocation
import Foundation

/// 中国大陆地图（GCJ-02）坐标修正。
///
/// CoreLocation 输出 WGS-84（真实 GPS），而中国区地图瓦片使用加密的 GCJ-02 坐标系，
/// 直接绘制会整体偏移数百米。存储始终保留 WGS-84 原始数据，仅在渲染轨迹时转换；
/// 系统的蓝色定位点由 Apple 内部处理，无需转换。
///
/// 转换使用业界通用的公开近似算法（克拉索夫斯基椭球），精度约 1-2 米。

private let semiMajorAxis = 6_378_245.0 // 克拉索夫斯基椭球长半轴（米）
private let eccentricitySquared = 0.006_693_421_622_965_943 // 第一偏心率平方

/// 中国大陆粗略边界（境外/港澳台原样返回；港澳台与境外地图不使用 GCJ-02）
func isInMainlandChina(_ coordinate: CLLocationCoordinate2D) -> Bool {
  coordinate.longitude >= 72.004 && coordinate.longitude <= 137.8347
    && coordinate.latitude >= 0.8293 && coordinate.latitude <= 55.8271
}

/// 渲染用的坐标：中国境内 WGS-84 → GCJ-02，境外原样返回
func displayCoordinate(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
  guard isInMainlandChina(coordinate) else { return coordinate }

  let x = coordinate.longitude - 105.0
  let y = coordinate.latitude - 35.0

  var dLat = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(max(0, x))
  dLat += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
  dLat += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
  dLat += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0

  var dLon = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(max(0, x))
  dLon += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
  dLon += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
  dLon += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0

  let radLat = coordinate.latitude / 180.0 * .pi
  var magic = sin(radLat)
  magic = 1 - eccentricitySquared * magic * magic
  let sqrtMagic = sqrt(magic)
  dLat = (dLat * 180.0) / ((semiMajorAxis * (1 - eccentricitySquared)) / (magic * sqrtMagic) * .pi)
  dLon = (dLon * 180.0) / (semiMajorAxis / sqrtMagic * cos(radLat) * .pi)

  return CLLocationCoordinate2D(
    latitude: coordinate.latitude + dLat,
    longitude: coordinate.longitude + dLon
  )
}

extension [RoutePoint] {
  /// 渲染用的轨迹坐标数组
  var displayCoordinates: [CLLocationCoordinate2D] {
    map { displayCoordinate($0.coordinate) }
  }
}
