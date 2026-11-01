import ComposableArchitecture
import CoreLocation
import Foundation

/// CoreLocation 的 TCA 依赖包装，以 AsyncStream 暴露定位流
@DependencyClient
struct LocationClient {
  var authorizationStatus: @Sendable () -> CLAuthorizationStatus = { .notDetermined }
  var requestWhenInUse: @Sendable () -> Void = {}
  var startUpdates: @Sendable () -> Void = {}
  var stopUpdates: @Sendable () -> Void = {}
  var locations: @Sendable () -> AsyncStream<CLLocation> = { AsyncStream { $0.finish() } }
}

// MARK: - Live 实现

private final class LocationManager: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
  private let manager = CLLocationManager()
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<CLLocation>.Continuation] = [:]

  override init() {
    super.init()
    manager.delegate = self
    manager.activityType = .fitness
    manager.distanceFilter = 5 // 米，由系统先过滤一次细碎更新
    manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
    manager.allowsBackgroundLocationUpdates = true // 配合 Info.plist 的 UIBackgroundModes
    manager.showsBackgroundLocationIndicator = true // 锁屏时显示蓝色定位指示条
  }

  var authorizationStatus: CLAuthorizationStatus {
    manager.authorizationStatus
  }

  func requestWhenInUse() {
    manager.requestWhenInUseAuthorization()
  }

  func startUpdatingLocation() {
    manager.startUpdatingLocation()
  }

  func stopUpdatingLocation() {
    manager.stopUpdatingLocation()
  }

  /// 每次调用产生一个新的流；所有活跃流共享定位更新
  var locations: AsyncStream<CLLocation> {
    AsyncStream { continuation in
      let id = UUID()
      lock.lock()
      continuations[id] = continuation
      lock.unlock()
      continuation.onTermination = { [weak self] _ in
        self?.removeContinuation(id)
      }
    }
  }

  private func removeContinuation(_ id: UUID) {
    lock.lock()
    continuations[id] = nil
    lock.unlock()
  }

  func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    lock.lock()
    let targets = Array(continuations.values)
    lock.unlock()
    for continuation in targets {
      for location in locations {
        continuation.yield(location)
      }
    }
  }
}

extension LocationClient: DependencyKey {
  static let liveValue: Self = {
    let locationManager = LocationManager()
    return Self(
      authorizationStatus: { locationManager.authorizationStatus },
      requestWhenInUse: { locationManager.requestWhenInUse() },
      startUpdates: { locationManager.startUpdatingLocation() },
      stopUpdates: { locationManager.stopUpdatingLocation() },
      locations: { locationManager.locations }
    )
  }()
}

extension DependencyValues {
  var locationClient: LocationClient {
    get { self[LocationClient.self] }
    set { self[LocationClient.self] = newValue }
  }
}
