import CoreLocation
import Foundation

/// 轨迹点（仅保留渲染与计算所需字段，便于 Codable 与 Equatable）
struct RoutePoint: Codable, Equatable, Hashable {
  var lat: Double
  var lon: Double

  init(lat: Double, lon: Double) {
    self.lat = lat
    self.lon = lon
  }

  var coordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: lat, longitude: lon)
  }
}

/// 一次跑步记录
struct Run: Codable, Identifiable, Equatable, Hashable {
  let id: UUID
  let startedAt: Date
  /// 实际跑步秒数（不含暂停）
  var duration: TimeInterval
  /// 总距离（米）
  var distance: Double
  /// 轨迹
  var route: [RoutePoint]
  /// 软删除标记：删除只隐藏不真删（防数据丢失），可在历史页"显示所有数据"中恢复
  var isHidden: Bool = false

  init(
    id: UUID = UUID(),
    startedAt: Date,
    duration: TimeInterval,
    distance: Double,
    route: [RoutePoint] = [],
    isHidden: Bool = false
  ) {
    self.id = id
    self.startedAt = startedAt
    self.duration = duration
    self.distance = distance
    self.route = route
    self.isHidden = isHidden
  }

  /// 兼容旧版本 JSON（无 isHidden 字段 → 视为 false）
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    duration = try container.decode(TimeInterval.self, forKey: .duration)
    distance = try container.decode(Double.self, forKey: .distance)
    route = try container.decode([RoutePoint].self, forKey: .route)
    isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
  }

  var coordinates: [CLLocationCoordinate2D] {
    route.map(\.coordinate)
  }
}

/// 进行中的跑步草稿：App 被系统 kill 时用于恢复，最多丢一个 checkpoint 周期（10 秒）的数据
struct RunDraft: Codable, Equatable {
  var startedAt: Date
  var elapsed: TimeInterval
  var distance: Double
  var route: [RoutePoint]
  /// 恢复后的会话状态：true → paused（等用户点继续），false → running（立即重启 GPS/计时）
  var isPaused: Bool

  init(
    startedAt: Date,
    elapsed: TimeInterval,
    distance: Double,
    route: [RoutePoint],
    isPaused: Bool
  ) {
    self.startedAt = startedAt
    self.elapsed = elapsed
    self.distance = distance
    self.route = route
    self.isPaused = isPaused
  }
}
