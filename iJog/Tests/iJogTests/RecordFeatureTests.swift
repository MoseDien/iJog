import Clocks
import ComposableArchitecture
import CoreLocation
import Testing
@testable import iJog

/// 测试用的引用盒子（在 @Sendable 闭包中收集结果）
private final class Ref<T>: @unchecked Sendable {
  var value: T
  init(_ value: T) { self.value = value }
}

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
private let fixedID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")!

/// CLLocation.speed 只读，用子类注入测试速度；默认 3.0 m/s（快于自动暂停阈值）
private func location(_ point: RoutePoint, speed: Double = 3.0) -> CLLocation {
  FakeSpeedLocation(point, speed: speed)
}

private final class FakeSpeedLocation: CLLocation, @unchecked Sendable {
  private let injectedSpeed: Double

  init(_ point: RoutePoint, speed: Double) {
    self.injectedSpeed = speed
    super.init(
      coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon),
      altitude: 0,
      horizontalAccuracy: 5,
      verticalAccuracy: 5,
      timestamp: fixedDate
    )
  }

  override var speed: CLLocationSpeed { injectedSpeed }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

// MARK: - 基础记录流程

@Test func recordTracksAndSaves() async throws {
  let clock = TestClock()
  let (locations, continuation) = AsyncStream<CLLocation>.makeStream()
  let saved = Ref<[Run]>([])
  let cleared = Ref<Int>(0)

  let store = TestStore(initialState: RecordFeature.State()) {
    RecordFeature()
  } withDependencies: {
    $0.continuousClock = clock
    $0.date = DateGenerator { fixedDate }
    $0.uuid = UUIDGenerator { fixedID }
    $0.locationClient.authorizationStatus = { .authorizedWhenInUse }
    $0.locationClient.requestWhenInUse = {}
    $0.locationClient.startUpdates = {}
    $0.locationClient.stopUpdates = {}
    $0.locationClient.locations = { locations }
    $0.runsRepository.save = { saved.value.append($0) }
    $0.runsRepository.saveDraft = { _ in }
    $0.runsRepository.clearDraft = { cleared.value += 1 }
  }

  await store.send(.startTapped) {
    $0.session = .running
    $0.startedAt = fixedDate
  }

  // 计时 3 秒（首次定位前 lastSpeed 为 nil，正常计时）
  await clock.advance(by: .seconds(3))
  await store.receive(.timerTicked) { $0.elapsed = 1 }
  await store.receive(.timerTicked) { $0.elapsed = 2 }
  await store.receive(.timerTicked) { $0.elapsed = 3 }

  // 0.01° 正方形四角（赤道附近），总距离 ≈ 3.34 km
  let a = RoutePoint(lat: 0, lon: 0)
  let b = RoutePoint(lat: 0.01, lon: 0)
  let c = RoutePoint(lat: 0.01, lon: 0.01)
  let d = RoutePoint(lat: 0, lon: 0.01)

  let expectedDistance =
    haversine(a.coordinate, b.coordinate)
    + haversine(b.coordinate, c.coordinate)
    + haversine(c.coordinate, d.coordinate)
  #expect(abs(expectedDistance - 3337) < 20) // haversine 本身已在 FormatTests 校准

  continuation.yield(location(a))
  await store.receive(.locationUpdated(point: a, speed: 3.0)) {
    $0.route = [a]
    $0.lastSpeed = 3.0
  }

  continuation.yield(location(b))
  await store.receive(.locationUpdated(point: b, speed: 3.0)) {
    $0.distance = haversine(a.coordinate, b.coordinate)
    $0.route = [a, b]
  }

  continuation.yield(location(c))
  await store.receive(.locationUpdated(point: c, speed: 3.0)) {
    $0.distance = haversine(a.coordinate, b.coordinate) + haversine(b.coordinate, c.coordinate)
    $0.route = [a, b, c]
  }

  continuation.yield(location(d))
  await store.receive(.locationUpdated(point: d, speed: 3.0)) {
    $0.distance = expectedDistance
    $0.route = [a, b, c, d]
  }

  // 结束并保存
  await store.send(.finishTapped) {
    $0.session = .idle
  }

  let expectedRun = Run(
    id: fixedID,
    startedAt: fixedDate,
    duration: 3,
    distance: expectedDistance,
    route: [a, b, c, d]
  )

  // 保存由 effect 异步完成，栈元素 ID 由全局生成器分配、无法在断言闭包中预知，
  // 因此此步关闭穷尽比较，改为手动校验关键字段
  store.exhaustivity = .off(showSkippedAssertions: false)
  await store.receive(.saveCompleted(expectedRun))
  store.exhaustivity = .on

  #expect(saved.value == [expectedRun])
  // 草稿被清除：开始新跑步时 1 次 + 保存成功后 1 次
  #expect(cleared.value == 2)
  #expect(store.state.startedAt == nil)
  #expect(store.state.elapsed == 0)
  #expect(store.state.distance == 0)
  #expect(store.state.route.isEmpty)
  #expect(store.state.path.count == 1)
  #expect(store.state.path.first?.run == expectedRun)
}

@Test func jitterPointsAreFiltered() async throws {
  let clock = TestClock()
  let (locations, continuation) = AsyncStream<CLLocation>.makeStream()

  let store = TestStore(initialState: RecordFeature.State()) {
    RecordFeature()
  } withDependencies: {
    $0.continuousClock = clock
    $0.date = DateGenerator { fixedDate }
    $0.locationClient.authorizationStatus = { .authorizedWhenInUse }
    $0.locationClient.requestWhenInUse = {}
    $0.locationClient.startUpdates = {}
    $0.locationClient.stopUpdates = {}
    $0.locationClient.locations = { locations }
    $0.runsRepository.saveDraft = { _ in }
    $0.runsRepository.clearDraft = {}
  }

  await store.send(.startTapped) {
    $0.session = .running
    $0.startedAt = fixedDate
  }

  let a = RoutePoint(lat: 0, lon: 0)
  let jitter = RoutePoint(lat: 0.00001, lon: 0) // 距 a 约 1.1 米，应被忽略
  let b = RoutePoint(lat: 0, lon: 0.01)

  continuation.yield(location(a))
  await store.receive(.locationUpdated(point: a, speed: 3.0)) {
    $0.route = [a]
    $0.lastSpeed = 3.0
  }

  continuation.yield(location(jitter))
  await store.receive(.locationUpdated(point: jitter, speed: 3.0)) // 距离不足 2 米，无状态变化

  continuation.yield(location(b))
  await store.receive(.locationUpdated(point: b, speed: 3.0)) {
    $0.distance = haversine(a.coordinate, b.coordinate) // 抖动点没有贡献距离
    $0.route = [a, b]
  }

  // 测试直接结束，跳过仍在运行的计时/定位长驻 effect
  await store.skipInFlightEffects()
}

@Test func pauseStopsTimerAndResumeContinues() async throws {
  let clock = TestClock()
  let (locations, _) = AsyncStream<CLLocation>.makeStream()

  let store = TestStore(initialState: RecordFeature.State()) {
    RecordFeature()
  } withDependencies: {
    $0.continuousClock = clock
    $0.date = DateGenerator { fixedDate }
    $0.locationClient.authorizationStatus = { .authorizedWhenInUse }
    $0.locationClient.requestWhenInUse = {}
    $0.locationClient.startUpdates = {}
    $0.locationClient.stopUpdates = {}
    $0.locationClient.locations = { locations }
    $0.runsRepository.saveDraft = { _ in }
    $0.runsRepository.clearDraft = {}
  }

  await store.send(.startTapped) {
    $0.session = .running
    $0.startedAt = fixedDate
  }

  await clock.advance(by: .seconds(2))
  await store.receive(.timerTicked) { $0.elapsed = 1 }
  await store.receive(.timerTicked) { $0.elapsed = 2 }

  // 暂停：计时停止
  await store.send(.pauseTapped) {
    $0.session = .paused
    $0.lastSpeed = nil
  }
  await clock.advance(by: .seconds(5)) // 期间无任何 tick

  // 继续：计时恢复，从 2 秒接着数
  await store.send(.resumeTapped) {
    $0.session = .running
  }
  await clock.advance(by: .seconds(1))
  await store.receive(.timerTicked) { $0.elapsed = 3 }

  // 测试直接结束，跳过仍在运行的计时/定位长驻 effect
  await store.skipInFlightEffects()
}

// MARK: - 自动暂停（慢速自动排除）

/// 把 store 推进到"运行中且已自动暂停"的状态：a(3.0) → 2 秒 → b(1.5) → 10 秒慢速。
/// 返回 store 与定位流 continuation，供调用方继续喂点；prepare 可追加依赖覆盖。
private func makeAutoPausedStore(
  clock: TestClock<Duration>,
  prepare: ((inout DependencyValues) -> Void)? = nil
) async throws -> (
  TestStore<RecordFeature.State, RecordFeature.Action>,
  AsyncStream<CLLocation>.Continuation
) {
  let (locations, continuation) = AsyncStream<CLLocation>.makeStream()
  let store = TestStore(initialState: RecordFeature.State()) {
    RecordFeature()
  } withDependencies: { dependencies in
    dependencies.continuousClock = clock
    dependencies.date = DateGenerator { fixedDate }
    dependencies.locationClient.authorizationStatus = { .authorizedWhenInUse }
    dependencies.locationClient.requestWhenInUse = {}
    dependencies.locationClient.startUpdates = {}
    dependencies.locationClient.stopUpdates = {}
    dependencies.locationClient.locations = { locations }
    dependencies.runsRepository.saveDraft = { _ in }
    dependencies.runsRepository.clearDraft = {}
    if let prepare {
      var values = dependencies
      prepare(&values)
      dependencies = values
    }
  }

  await store.send(.startTapped) {
    $0.session = .running
    $0.startedAt = fixedDate
  }

  let a = RoutePoint(lat: 0, lon: 0)
  continuation.yield(location(a))
  await store.receive(.locationUpdated(point: a, speed: 3.0)) {
    $0.route = [a]
    $0.lastSpeed = 3.0
  }

  await clock.advance(by: .seconds(2))
  await store.receive(.timerTicked) { $0.elapsed = 1 }
  await store.receive(.timerTicked) { $0.elapsed = 2 }

  let b = RoutePoint(lat: 0, lon: 0.01)
  continuation.yield(location(b, speed: 1.5))
  await store.receive(.locationUpdated(point: b, speed: 1.5)) {
    $0.distance = haversine(a.coordinate, b.coordinate)
    $0.route = [a, b]
    $0.lastSpeed = 1.5
  }

  await clock.advance(by: .seconds(9))
  for second in 1...9 {
    await store.receive(.timerTicked) { $0.slowSeconds = second }
  }
  await clock.advance(by: .seconds(1))
  await store.receive(.timerTicked) {
    $0.slowSeconds = 10
    $0.isAutoPaused = true
  }
  return (store, continuation)
}

@Test func autoPausesAfterSustainedSlowSpeed() async throws {
  let clock = TestClock()
  let (store, continuation) = try await makeAutoPausedStore(clock: clock)

  // 自动暂停期间：慢速点被丢弃（仅更新 lastSpeed），计时冻结
  let c = RoutePoint(lat: 0, lon: 0.02)
  continuation.yield(location(c, speed: 1.2))
  await store.receive(.locationUpdated(point: c, speed: 1.2)) {
    $0.lastSpeed = 1.2
  }

  await clock.advance(by: .seconds(2))
  await store.receive(.timerTicked) { $0.slowSeconds = 11 } // 自动暂停中累计暂停时长
  await store.receive(.timerTicked) { $0.slowSeconds = 12 }

  #expect(store.state.isAutoPaused)
  #expect(store.state.elapsed == 2) // 冻结在进入慢速前
  #expect(store.state.route.count == 2) // 慢速点未进轨迹

  await store.skipInFlightEffects()
}

@Test func resumesWhenSpeedRecovers() async throws {
  let clock = TestClock()
  let (store, continuation) = try await makeAutoPausedStore(clock: clock)

  let a = RoutePoint(lat: 0, lon: 0)
  let b = RoutePoint(lat: 0, lon: 0.01)
  let d = RoutePoint(lat: 0, lon: 0.02) // 远点，速度 3.0 触发恢复

  continuation.yield(location(d, speed: 3.0))
  await store.receive(.locationUpdated(point: d, speed: 3.0)) {
    $0.isAutoPaused = false
    $0.slowSeconds = 0
    $0.lastSpeed = 3.0
    $0.distance = haversine(a.coordinate, b.coordinate) + haversine(b.coordinate, d.coordinate)
    $0.route = [a, b, d]
  }

  // 恢复后计时继续
  await clock.advance(by: .seconds(1))
  await store.receive(.timerTicked) { $0.elapsed = 3 }

  await store.skipInFlightEffects()
}

@Test func hysteresisBetweenThresholds() async throws {
  let clock = TestClock()
  let (store, continuation) = try await makeAutoPausedStore(clock: clock)

  // 速度 2.2 m/s 介于慢速阈值(2.0)与恢复阈值(2.5)之间：保持暂停，点被丢弃
  let c = RoutePoint(lat: 0, lon: 0.02)
  continuation.yield(location(c, speed: 2.2))
  await store.receive(.locationUpdated(point: c, speed: 2.2)) {
    $0.lastSpeed = 2.2
  }

  #expect(store.state.isAutoPaused)
  #expect(store.state.route.count == 2)

  await store.skipInFlightEffects()
}

// MARK: - 慢速超 5 分钟自动结束

@Test func autoStopsAfterFiveMinutesOfAutoPause() async throws {
  let clock = TestClock()
  let saved = Ref<[Run]>([])

  let (store, _) = try await makeAutoPausedStore(clock: clock) {
    $0.uuid = UUIDGenerator { fixedID }
    $0.runsRepository.save = { saved.value.append($0) }
  }

  // 自动暂停中继续累计：10(确认窗口) + 299 = 309 秒，仍未触发
  await clock.advance(by: .seconds(299))
  for second in 11...309 {
    await store.receive(.timerTicked) { $0.slowSeconds = second }
  }

  // 第 310 秒（= 确认窗口 10s + 暂停 300s）自动结束并保存
  await clock.advance(by: .seconds(1))
  await store.receive(.timerTicked) {
    $0.slowSeconds = 310
    $0.session = .idle
  }

  let a = RoutePoint(lat: 0, lon: 0)
  let b = RoutePoint(lat: 0, lon: 0.01)
  let expectedRun = Run(
    id: fixedID,
    startedAt: fixedDate,
    duration: 2,
    distance: haversine(a.coordinate, b.coordinate),
    route: [a, b]
  )

  store.exhaustivity = .off(showSkippedAssertions: false)
  await store.receive(.saveCompleted(expectedRun))
  store.exhaustivity = .on

  #expect(saved.value == [expectedRun])
  #expect(store.state.session == .idle)
  #expect(store.state.elapsed == 0)
  #expect(store.state.route.isEmpty)
  #expect(store.state.path.count == 1)
}

@Test func autoStopDiscardsRunWithoutMovement() async throws {
  let clock = TestClock()
  let (locations, continuation) = AsyncStream<CLLocation>.makeStream()
  let saved = Ref<[Run]>([])

  let store = TestStore(initialState: RecordFeature.State()) {
    RecordFeature()
  } withDependencies: {
    $0.continuousClock = clock
    $0.date = DateGenerator { fixedDate }
    $0.uuid = UUIDGenerator { fixedID }
    $0.locationClient.authorizationStatus = { .authorizedWhenInUse }
    $0.locationClient.requestWhenInUse = {}
    $0.locationClient.startUpdates = {}
    $0.locationClient.stopUpdates = {}
    $0.locationClient.locations = { locations }
    $0.runsRepository.save = { saved.value.append($0) }
    $0.runsRepository.saveDraft = { _ in }
    $0.runsRepository.clearDraft = {}
  }

  await store.send(.startTapped) {
    $0.session = .running
    $0.startedAt = fixedDate
  }

  // 一个定位点 + 之后的抖动点：lastSpeed 慢速但轨迹不足 2 个点
  let a = RoutePoint(lat: 0, lon: 0)
  let jitter = RoutePoint(lat: 0.000001, lon: 0) // ~0.1 米，被抖动过滤
  continuation.yield(location(a, speed: 3.0))
  await store.receive(.locationUpdated(point: a, speed: 3.0)) {
    $0.route = [a]
    $0.lastSpeed = 3.0
  }
  continuation.yield(location(jitter, speed: 1.0))
  await store.receive(.locationUpdated(point: jitter, speed: 1.0)) {
    $0.lastSpeed = 1.0
  }

  // 10 秒慢速进入自动暂停，再 300 秒触发自动结束
  await clock.advance(by: .seconds(10))
  for second in 1...10 {
    await store.receive(.timerTicked) {
      $0.slowSeconds = second
      if second == 10 { $0.isAutoPaused = true }
    }
  }
  await clock.advance(by: .seconds(300))
  for second in 11...309 {
    await store.receive(.timerTicked) { $0.slowSeconds = second }
  }
  await clock.advance(by: .seconds(1))
  await store.receive(.timerTicked) {
    // 丢弃路径：reset 清空全部进行中状态（含 slowSeconds）
    $0.session = .idle
    $0.startedAt = nil
    $0.elapsed = 0
    $0.distance = 0
    $0.route = []
    $0.isAutoPaused = false
    $0.lastSpeed = nil
    $0.slowSeconds = 0
  }

  // 无有效轨迹：不保存，静默丢弃
  #expect(saved.value.isEmpty)
  #expect(store.state.session == .idle)
}

@Test func noAutoPauseWhenDisabled() async throws {
  let clock = TestClock()
  let (locations, continuation) = AsyncStream<CLLocation>.makeStream()

  let store = TestStore(initialState: RecordFeature.State()) {
    RecordFeature()
  } withDependencies: {
    $0.continuousClock = clock
    $0.date = DateGenerator { fixedDate }
    $0.locationClient.authorizationStatus = { .authorizedWhenInUse }
    $0.locationClient.requestWhenInUse = {}
    $0.locationClient.startUpdates = {}
    $0.locationClient.stopUpdates = {}
    $0.locationClient.locations = { locations }
    $0.runsRepository.saveDraft = { _ in }
    $0.runsRepository.clearDraft = {}
  }

  await store.send(.toggleAutoPauseTapped) {
    $0.autoPauseEnabled = false
  }

  await store.send(.startTapped) {
    $0.session = .running
    $0.startedAt = fixedDate
  }

  let a = RoutePoint(lat: 0, lon: 0)
  continuation.yield(location(a, speed: 1.0))
  await store.receive(.locationUpdated(point: a, speed: 1.0)) {
    $0.route = [a]
    $0.lastSpeed = 1.0
  }

  // 慢速 12 秒：开关关闭，照常计时，不进入自动暂停
  await clock.advance(by: .seconds(12))
  for second in 1...12 {
    await store.receive(.timerTicked) { $0.elapsed = Double(second) }
  }

  #expect(!store.state.isAutoPaused)
  #expect(store.state.slowSeconds == 0)

  await store.skipInFlightEffects()
}

@Test func timerRunsNormallyBeforeFirstSpeedReading() async throws {
  let clock = TestClock()
  let (locations, _) = AsyncStream<CLLocation>.makeStream()

  let store = TestStore(initialState: RecordFeature.State()) {
    RecordFeature()
  } withDependencies: {
    $0.continuousClock = clock
    $0.date = DateGenerator { fixedDate }
    $0.locationClient.authorizationStatus = { .authorizedWhenInUse }
    $0.locationClient.requestWhenInUse = {}
    $0.locationClient.startUpdates = {}
    $0.locationClient.stopUpdates = {}
    $0.locationClient.locations = { locations }
    $0.runsRepository.saveDraft = { _ in }
    $0.runsRepository.clearDraft = {}
  }

  await store.send(.startTapped) {
    $0.session = .running
    $0.startedAt = fixedDate
  }

  // GPS 尚未给出首个速度读数（lastSpeed == nil）：正常计时，不累计慢速
  await clock.advance(by: .seconds(3))
  await store.receive(.timerTicked) { $0.elapsed = 1 }
  await store.receive(.timerTicked) { $0.elapsed = 2 }
  await store.receive(.timerTicked) { $0.elapsed = 3 }

  #expect(!store.state.isAutoPaused)
  #expect(store.state.slowSeconds == 0)

  await store.skipInFlightEffects()
}

// MARK: - 草稿恢复（崩溃保护）

@Test func checkpointsDraftEveryTenSeconds() async throws {
  let clock = TestClock()
  let (locations, _) = AsyncStream<CLLocation>.makeStream()
  let drafts = Ref<[RunDraft]>([])

  let store = TestStore(initialState: RecordFeature.State()) {
    RecordFeature()
  } withDependencies: {
    $0.continuousClock = clock
    $0.date = DateGenerator { fixedDate }
    $0.locationClient.authorizationStatus = { .authorizedWhenInUse }
    $0.locationClient.requestWhenInUse = {}
    $0.locationClient.startUpdates = {}
    $0.locationClient.stopUpdates = {}
    $0.locationClient.locations = { locations }
    $0.runsRepository.saveDraft = { drafts.value.append($0) }
    $0.runsRepository.clearDraft = {}
  }

  await store.send(.startTapped) {
    $0.session = .running
    $0.startedAt = fixedDate
  }

  await clock.advance(by: .seconds(12))
  for second in 1...12 {
    await store.receive(.timerTicked) { $0.elapsed = Double(second) }
  }
  await store.skipInFlightEffects()

  // 仅在 10 秒边界写入（12 秒处未到下一个边界）
  let expected = RunDraft(
    startedAt: fixedDate, elapsed: 10, distance: 0, route: [], isPaused: false
  )
  #expect(drafts.value == [expected])
}

@Test func persistsDraftOnManualPause() async throws {
  let clock = TestClock()
  let (locations, _) = AsyncStream<CLLocation>.makeStream()
  let drafts = Ref<[RunDraft]>([])

  let store = TestStore(initialState: RecordFeature.State()) {
    RecordFeature()
  } withDependencies: {
    $0.continuousClock = clock
    $0.date = DateGenerator { fixedDate }
    $0.locationClient.authorizationStatus = { .authorizedWhenInUse }
    $0.locationClient.requestWhenInUse = {}
    $0.locationClient.startUpdates = {}
    $0.locationClient.stopUpdates = {}
    $0.locationClient.locations = { locations }
    $0.runsRepository.saveDraft = { drafts.value.append($0) }
    $0.runsRepository.clearDraft = {}
  }

  await store.send(.startTapped) {
    $0.session = .running
    $0.startedAt = fixedDate
  }
  await clock.advance(by: .seconds(2))
  await store.receive(.timerTicked) { $0.elapsed = 1 }
  await store.receive(.timerTicked) { $0.elapsed = 2 }

  let pauseTask = await store.send(.pauseTapped) {
    $0.session = .paused
    $0.lastSpeed = nil
  }
  await pauseTask.finish() // 等待 checkpoint 写盘完成

  let expected = RunDraft(
    startedAt: fixedDate, elapsed: 2, distance: 0, route: [], isPaused: true
  )
  #expect(drafts.value == [expected])
}

@Test func restoresRunningDraftOnLaunch() async throws {
  let clock = TestClock()
  let (locations, _) = AsyncStream<CLLocation>.makeStream()
  let draft = RunDraft(
    startedAt: fixedDate,
    elapsed: 97,
    distance: 1200,
    route: [RoutePoint(lat: 0, lon: 0), RoutePoint(lat: 0, lon: 0.01)],
    isPaused: false
  )

  let store = TestStore(initialState: RecordFeature.State()) {
    RecordFeature()
  } withDependencies: {
    $0.continuousClock = clock
    $0.date = DateGenerator { fixedDate }
    $0.locationClient.authorizationStatus = { .authorizedWhenInUse }
    $0.locationClient.requestWhenInUse = {}
    $0.locationClient.startUpdates = {}
    $0.locationClient.stopUpdates = {}
    $0.locationClient.locations = { locations }
    $0.runsRepository.loadDraft = { draft }
    $0.runsRepository.saveDraft = { _ in }
    $0.runsRepository.clearDraft = {}
  }

  await store.send(.onAppear)
  // AlertState 全量断言较啰嗦，这里只校验 pendingDraft，弹窗内容另由 UI 层保证
  store.exhaustivity = .off(showSkippedAssertions: false)
  await store.receive(.draftLoaded(draft))
  store.exhaustivity = .on
  #expect(store.state.pendingDraft == draft)
  #expect(store.state.alert != nil)

  // 点"恢复"：状态还原并重启 GPS/计时（alert 由 TCA 展示机制自动清除）
  await store.send(.alert(.presented(.restoreButtonTapped))) {
    $0.pendingDraft = nil
    $0.alert = nil
    $0.session = .running
    $0.startedAt = draft.startedAt
    $0.elapsed = draft.elapsed
    $0.distance = draft.distance
    $0.route = draft.route
  }

  await store.skipInFlightEffects()
}

@Test func restoresPausedDraftAsPaused() async throws {
  let clock = TestClock()
  let (locations, _) = AsyncStream<CLLocation>.makeStream()
  let draft = RunDraft(
    startedAt: fixedDate,
    elapsed: 60,
    distance: 800,
    route: [RoutePoint(lat: 0, lon: 0)],
    isPaused: true
  )

  let store = TestStore(initialState: RecordFeature.State()) {
    RecordFeature()
  } withDependencies: {
    $0.continuousClock = clock
    $0.date = DateGenerator { fixedDate }
    $0.locationClient.authorizationStatus = { .authorizedWhenInUse }
    $0.locationClient.requestWhenInUse = {}
    $0.locationClient.startUpdates = {}
    $0.locationClient.stopUpdates = {}
    $0.locationClient.locations = { locations }
    $0.runsRepository.loadDraft = { draft }
    $0.runsRepository.saveDraft = { _ in }
    $0.runsRepository.clearDraft = {}
  }

  await store.send(.onAppear)
  store.exhaustivity = .off(showSkippedAssertions: false)
  await store.receive(.draftLoaded(draft))
  store.exhaustivity = .on

  // 恢复为 paused：不启动 GPS/计时，等用户点"继续"（alert 由展示机制自动清除）
  await store.send(.alert(.presented(.restoreButtonTapped))) {
    $0.pendingDraft = nil
    $0.alert = nil
    $0.session = .paused
    $0.startedAt = draft.startedAt
    $0.elapsed = draft.elapsed
    $0.distance = draft.distance
    $0.route = draft.route
  }
}

@Test func discardsDraftOnLaunch() async throws {
  let clock = TestClock()
  let (locations, _) = AsyncStream<CLLocation>.makeStream()
  let draft = RunDraft(
    startedAt: fixedDate, elapsed: 30, distance: 100, route: [], isPaused: true
  )
  let cleared = Ref<Int>(0)

  let store = TestStore(initialState: RecordFeature.State()) {
    RecordFeature()
  } withDependencies: {
    $0.continuousClock = clock
    $0.date = DateGenerator { fixedDate }
    $0.locationClient.authorizationStatus = { .authorizedWhenInUse }
    $0.locationClient.requestWhenInUse = {}
    $0.locationClient.startUpdates = {}
    $0.locationClient.stopUpdates = {}
    $0.locationClient.locations = { locations }
    $0.runsRepository.loadDraft = { draft }
    $0.runsRepository.saveDraft = { _ in }
    $0.runsRepository.clearDraft = { cleared.value += 1 }
  }

  await store.send(.onAppear)
  store.exhaustivity = .off(showSkippedAssertions: false)
  await store.receive(.draftLoaded(draft))
  store.exhaustivity = .on

  let discardTask = await store.send(.alert(.presented(.discardButtonTapped))) {
    $0.pendingDraft = nil
    $0.alert = nil
  }
  await discardTask.finish() // 等待 clearDraft 完成

  #expect(cleared.value == 1)
}

@Test func saveFailureKeepsDraftForNextLaunch() async throws {
  struct SaveError: Error {}
  let clock = TestClock()
  let (locations, _) = AsyncStream<CLLocation>.makeStream()
  let cleared = Ref<Int>(0)

  let store = TestStore(initialState: RecordFeature.State()) {
    RecordFeature()
  } withDependencies: {
    $0.continuousClock = clock
    $0.date = DateGenerator { fixedDate }
    $0.uuid = UUIDGenerator { fixedID }
    $0.locationClient.authorizationStatus = { .authorizedWhenInUse }
    $0.locationClient.requestWhenInUse = {}
    $0.locationClient.startUpdates = {}
    $0.locationClient.stopUpdates = {}
    $0.locationClient.locations = { locations }
    $0.runsRepository.save = { _ in throw SaveError() }
    $0.runsRepository.saveDraft = { _ in }
    $0.runsRepository.clearDraft = { cleared.value += 1 }
  }

  await store.send(.startTapped) {
    $0.session = .running
    $0.startedAt = fixedDate
  }
  await clock.advance(by: .seconds(1))
  await store.receive(.timerTicked) { $0.elapsed = 1 }
  let finishTask = await store.send(.finishTapped) {
    $0.session = .idle
  }

  // 保存失败：不清草稿（下次启动可恢复），重置界面并提示
  store.exhaustivity = .off(showSkippedAssertions: false)
  await store.receive(.saveFailed)
  store.exhaustivity = .on
  await finishTask.finish()

  #expect(store.state.session == .idle)
  #expect(cleared.value == 1) // 仅开始新跑步时清了一次
}
