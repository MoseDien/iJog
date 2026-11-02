import ComposableArchitecture
import Foundation

/// 历史列表：加载、滑动隐藏/恢复（软删除）、栈导航到详情、iCloud 手动同步
@Reducer
struct HistoryFeature {
  @ObservableState
  struct State: Equatable {
    /// 全量记录（含已隐藏）
    var runs: IdentifiedArrayOf<Run> = []
    /// "显示所有数据"开关：开 → 连隐藏记录一起显示（会话内有效，默认关）
    var showsHidden = false
    var path = StackState<RunDetailFeature.State>()
    var isSyncing = false
    @Presents var alert: AlertState<Action.Alert>?

    /// 当前应显示的记录
    var visibleRuns: [Run] {
      showsHidden ? Array(runs) : runs.filter { !$0.isHidden }
    }
  }

  enum Action: Equatable {
    case onAppear
    case runsLoaded([Run])
    case loadFailed
    case toggleShowsHiddenTapped
    case hideTapped(UUID)
    case restoreTapped(UUID)
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

      case .toggleShowsHiddenTapped:
        state.showsHidden.toggle()
        return .none

      case let .hideTapped(id):
        // 软删除：只隐藏不真删（防数据丢失），文件保留在磁盘上
        state.runs[id: id]?.isHidden = true
        return .run { _ in
          try? runsRepository.setHidden(id, true)
        }

      case let .restoreTapped(id):
        state.runs[id: id]?.isHidden = false
        return .run { _ in
          try? runsRepository.setHidden(id, false)
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
        // 详情页"删除"同样走软删除：标记隐藏（列表按开关过滤），详情页 pop
        state.runs[id: runID]?.isHidden = true
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
