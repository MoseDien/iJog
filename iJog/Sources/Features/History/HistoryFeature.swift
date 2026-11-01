import ComposableArchitecture
import Foundation

/// 历史列表：加载、滑动删除、栈导航到详情、iCloud 手动同步
@Reducer
struct HistoryFeature {
  @ObservableState
  struct State: Equatable {
    var runs: IdentifiedArrayOf<Run> = []
    var path = StackState<RunDetailFeature.State>()
    var isSyncing = false
    @Presents var alert: AlertState<Action.Alert>?
  }

  enum Action: Equatable {
    case onAppear
    case runsLoaded([Run])
    case loadFailed
    case delete(IndexSet)
    case syncTapped
    case syncFinished(SyncReport)
    case syncUnavailable
    case syncFailed
    case alert(PresentationAction<Alert>)
    case path(StackAction<RunDetailFeature.State, RunDetailFeature.Action>)

    @CasePathable
    enum Alert: Equatable {}
  }

  @Dependency(\.runsRepository) var runsRepository
  @Dependency(\.cloudSyncClient) var cloudSyncClient

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        return .run { send in
          do {
            await send(.runsLoaded(try runsRepository.loadRuns()))
          } catch {
            await send(.loadFailed)
          }
        }

      case let .runsLoaded(runs):
        state.runs = IdentifiedArray(
          uniqueElements: runs.sorted { $0.startedAt > $1.startedAt }
        )
        return .none

      case .loadFailed:
        state.runs = []
        return .none

      case let .delete(indexSet):
        let ids = indexSet.map { state.runs[$0].id }
        state.runs.remove(atOffsets: indexSet)
        return .run { _ in
          for id in ids { try? runsRepository.delete(id) }
        }

      case .syncTapped:
        guard !state.isSyncing else { return .none }
        state.isSyncing = true
        return .run { send in
          guard cloudSyncClient.isAvailable() else {
            await send(.syncUnavailable)
            return
          }
          do {
            let report = try cloudSyncClient.sync()
            await send(.syncFinished(report))
          } catch {
            await send(.syncFailed)
          }
        }

      case let .syncFinished(report):
        state.isSyncing = false
        state.alert = AlertState {
          TextState(String(localized: "Sync Complete"))
        } message: {
          TextState(
            String(
              localized: "Uploaded \(report.uploaded), downloaded \(report.downloaded) runs."
            )
          )
        }
        // 同步可能下载了新记录，重新加载列表
        return .run { send in
          do {
            await send(.runsLoaded(try runsRepository.loadRuns()))
          } catch {
            await send(.loadFailed)
          }
        }

      case .syncUnavailable:
        state.isSyncing = false
        state.alert = AlertState {
          TextState(String(localized: "iCloud Unavailable"))
        } message: {
          TextState(
            String(localized: "Please sign in to iCloud in Settings and try again.")
          )
        }
        return .none

      case .syncFailed:
        state.isSyncing = false
        state.alert = AlertState {
          TextState(String(localized: "Sync Failed"))
        } message: {
          TextState(String(localized: "Please try again later."))
        }
        return .none

      case .alert:
        return .none

      case let .path(.element(id: childID, action: .delegate(.didDeleteRun(runID)))):
        state.runs.remove(id: runID)
        state.path.pop(from: childID)
        return .none

      case .path:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert) {
      EmptyReducer()
    }
    .forEach(\.path, action: \.path) {
      RunDetailFeature()
    }
  }
}
