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

@Test func deleteRemovesRunAndCallsRepository() async throws {
  let run = Run(
    id: UUID(uuidString: "CAFEBABE-0000-0000-0000-000000000002")!,
    startedAt: Date(timeIntervalSince1970: 3_000),
    duration: 600,
    distance: 1_000,
    route: []
  )
  let deleted = Ref<[UUID]>([])

  var initialState = HistoryFeature.State()
  initialState.runs = IdentifiedArray(uniqueElements: [run])

  let store = TestStore(initialState: initialState) {
    HistoryFeature()
  } withDependencies: {
    $0.runsRepository.delete = { deleted.value.append($0) }
  }

  let task = await store.send(.delete(IndexSet(integer: 0))) {
    $0.runs = []
  }
  await task.finish()

  #expect(deleted.value == [run.id])
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
