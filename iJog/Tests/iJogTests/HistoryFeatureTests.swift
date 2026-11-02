import ComposableArchitecture
import Foundation
import Testing
@testable import iJog

/// 测试用的引用盒子（在 @Sendable 闭包中收集结果）
private final class Ref<T>: @unchecked Sendable {
  var value: T
  init(_ value: T) { self.value = value }
}

@Test func loadsRunsSortedByDateDescending() async throws {
  let older = Run(
    startedAt: Date(timeIntervalSince1970: 1_000),
    duration: 600,
    distance: 1_000,
    route: []
  )
  let newer = Run(
    startedAt: Date(timeIntervalSince1970: 2_000),
    duration: 1_200,
    distance: 3_000,
    route: []
  )

  let store = TestStore(initialState: HistoryFeature.State()) {
    HistoryFeature()
  } withDependencies: {
    // 故意乱序返回
    $0.runsRepository.loadRuns = { [older, newer] }
  }

  await store.send(.onAppear)
  await store.receive(.runsLoaded([older, newer])) {
    $0.runs = IdentifiedArray(uniqueElements: [newer, older])
  }
}

@Test func hideMarksRunHiddenAndPersists() async throws {
  let run = Run(
    id: UUID(uuidString: "CAFEBABE-0000-0000-0000-000000000002")!,
    startedAt: Date(timeIntervalSince1970: 3_000),
    duration: 600,
    distance: 1_000,
    route: []
  )
  let hidden = Ref<[(UUID, Bool)]>([])

  var initialState = HistoryFeature.State()
  initialState.runs = IdentifiedArray(uniqueElements: [run])

  let store = TestStore(initialState: initialState) {
    HistoryFeature()
  } withDependencies: {
    $0.runsRepository.setHidden = { id, flag in hidden.value.append((id, flag)) }
  }

  // 软删除：记录仍在列表数据里，仅标记隐藏
  let task = await store.send(.hideTapped(run.id)) {
    $0.runs[id: run.id]?.isHidden = true
  }
  await task.finish()

  #expect(hidden.value.count == 1)
  #expect(hidden.value[0].0 == run.id && hidden.value[0].1)
  #expect(store.state.runs.count == 1)
}

@Test func restoreTappedUnhidesRun() async throws {
  let run = Run(
    id: UUID(uuidString: "CAFEBABE-0000-0000-0000-000000000003")!,
    startedAt: Date(timeIntervalSince1970: 3_000),
    duration: 600,
    distance: 1_000,
    route: [],
    isHidden: true
  )
  let hidden = Ref<[(UUID, Bool)]>([])

  var initialState = HistoryFeature.State()
  initialState.runs = IdentifiedArray(uniqueElements: [run])
  initialState.showsHidden = true

  let store = TestStore(initialState: initialState) {
    HistoryFeature()
  } withDependencies: {
    $0.runsRepository.setHidden = { id, flag in hidden.value.append((id, flag)) }
  }

  let task = await store.send(.restoreTapped(run.id)) {
    $0.runs[id: run.id]?.isHidden = false
  }
  await task.finish()

  #expect(hidden.value.count == 1)
  #expect(hidden.value[0].0 == run.id && !hidden.value[0].1)
}

@Test func showsHiddenToggleFiltersVisibleRuns() async throws {
  let visible = Run(
    id: UUID(uuidString: "CAFEBABE-0000-0000-0000-000000000004")!,
    startedAt: Date(timeIntervalSince1970: 2_000),
    duration: 1_200,
    distance: 3_000,
    route: []
  )
  let hidden = Run(
    id: UUID(uuidString: "CAFEBABE-0000-0000-0000-000000000005")!,
    startedAt: Date(timeIntervalSince1970: 1_000),
    duration: 600,
    distance: 1_000,
    route: [],
    isHidden: true
  )

  let store = TestStore(initialState: HistoryFeature.State()) {
    HistoryFeature()
  } withDependencies: {
    $0.runsRepository.loadRuns = { [visible, hidden] }
  }

  await store.send(.onAppear)
  await store.receive(.runsLoaded([visible, hidden])) {
    $0.runs = IdentifiedArray(uniqueElements: [visible, hidden])
  }

  // 默认只显示未隐藏的
  #expect(store.state.visibleRuns.map(\.id) == [visible.id])

  await store.send(.toggleShowsHiddenTapped) {
    $0.showsHidden = true
  }
  #expect(store.state.visibleRuns.map(\.id) == [visible.id, hidden.id])
}

@Test func detailDeleteHidesRunInsteadOfRemoving() async throws {
  let run = Run(
    id: UUID(uuidString: "CAFEBABE-0000-0000-0000-000000000006")!,
    startedAt: Date(timeIntervalSince1970: 3_000),
    duration: 600,
    distance: 1_000,
    route: []
  )

  var initialState = HistoryFeature.State()
  initialState.runs = IdentifiedArray(uniqueElements: [run])
  initialState.path.append(RunDetailFeature.State(run: run)) // 空栈首元素自动分配 ID 0
  let elementID: StackElementID = 0

  let store = TestStore(initialState: initialState) {
    HistoryFeature()
  } withDependencies: {
    $0.runsRepository.setHidden = { _, _ in }
  }

  // 详情页"删除"delegate：标记隐藏而非移除，详情页 pop
  await store.send(.path(.element(id: elementID, action: .delegate(.didDeleteRun(run.id))))) {
    $0.runs[id: run.id]?.isHidden = true
    $0.path.pop(from: elementID)
  }

  #expect(store.state.runs.count == 1)
  #expect(store.state.runs[id: run.id]?.isHidden == true)
  #expect(store.state.path.isEmpty)
}

// MARK: - Run 模型（软删除兼容）

@Test func runCodableHiddenFlagCompat() throws {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601

  // 旧版本 JSON 无 isHidden 字段 → 解码为 false
  let legacyJSON = """
    {"id":"DEADBEEF-0000-0000-0000-000000000001","startedAt":"2023-11-14T22:13:20Z","duration":600,"distance":1000,"route":[]}
    """
  let legacy = try decoder.decode(Run.self, from: Data(legacyJSON.utf8))
  #expect(legacy.isHidden == false)
  #expect(legacy.duration == 600)

  // 新版本编码 → 解码往返保留 isHidden
  var run = Run(
    id: UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000002")!,
    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
    duration: 1_200,
    distance: 3_000,
    route: []
  )
  run.isHidden = true
  let roundTripped = try decoder.decode(Run.self, from: try encoder.encode(run))
  #expect(roundTripped.isHidden == true)
  #expect(roundTripped == run)
}

@Test func loadFailureYieldsEmptyList() async throws {
  struct LoadError: Error {}

  var initialState = HistoryFeature.State()
  initialState.runs = IdentifiedArray(
    uniqueElements: [
      Run(startedAt: Date(timeIntervalSince1970: 0), duration: 1, distance: 1, route: [])
    ]
  )

  let store = TestStore(initialState: initialState) {
    HistoryFeature()
  } withDependencies: {
    $0.runsRepository.loadRuns = { throw LoadError() }
  }

  await store.send(.onAppear)
  await store.receive(.loadFailed) {
    $0.runs = []
  }
}

// MARK: - iCloud 手动同步

@Test func manualSyncMergesAndReloads() async throws {
  let report = SyncReport(uploaded: 2, downloaded: 1)
  let run = Run(
    startedAt: Date(timeIntervalSince1970: 2_000),
    duration: 1_200,
    distance: 3_000,
    route: []
  )

  let store = TestStore(initialState: HistoryFeature.State()) {
    HistoryFeature()
  } withDependencies: {
    $0.cloudSyncClient.isAvailable = { true }
    $0.cloudSyncClient.sync = { report }
    $0.runsRepository.loadRuns = { [run] }
  }

  await store.send(.syncTapped) {
    $0.isSyncing = true
  }

  // 结果弹窗内容由 UI 层保证，这里只校验状态与后续刷新
  store.exhaustivity = .off(showSkippedAssertions: false)
  await store.receive(.syncFinished(report))
  store.exhaustivity = .on
  #expect(!store.state.isSyncing)
  #expect(store.state.alert != nil)

  // 同步后重新加载列表
  await store.receive(.runsLoaded([run])) {
    $0.runs = IdentifiedArray(uniqueElements: [run])
  }
}

@Test func manualSyncReportsWhenICloudUnavailable() async throws {
  let store = TestStore(initialState: HistoryFeature.State()) {
    HistoryFeature()
  } withDependencies: {
    $0.cloudSyncClient.isAvailable = { false }
  }

  await store.send(.syncTapped) {
    $0.isSyncing = true
  }

  store.exhaustivity = .off(showSkippedAssertions: false)
  await store.receive(.syncUnavailable)
  store.exhaustivity = .on
  #expect(!store.state.isSyncing)
  #expect(store.state.alert != nil)
}

@Test func manualSyncReportsFailure() async throws {
  struct SyncError: Error {}

  let store = TestStore(initialState: HistoryFeature.State()) {
    HistoryFeature()
  } withDependencies: {
    $0.cloudSyncClient.isAvailable = { true }
    $0.cloudSyncClient.sync = { throw SyncError() }
  }

  await store.send(.syncTapped) {
    $0.isSyncing = true
  }

  store.exhaustivity = .off(showSkippedAssertions: false)
  await store.receive(.syncFailed)
  store.exhaustivity = .on
  #expect(!store.state.isSyncing)
  #expect(store.state.alert != nil)
}
