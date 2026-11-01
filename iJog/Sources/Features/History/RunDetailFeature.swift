import ComposableArchitecture
import Foundation

/// 单次跑步详情（只读展示 + 删除）
@Reducer
struct RunDetailFeature {
  @ObservableState
  struct State: Equatable {
    var run: Run
    @Presents var confirmationDialog: ConfirmationDialogState<Action.ConfirmationDialog>?

    init(run: Run) {
      self.run = run
    }
  }

  enum Action: Equatable {
    case deleteTapped
    case confirmationDialog(PresentationAction<ConfirmationDialog>)
    case delegate(Delegate)

    @CasePathable
    enum ConfirmationDialog: Equatable {
      case deleteButtonTapped
    }

    enum Delegate: Equatable {
      /// 删除已完成（含文件已不存在的情况），父级收到后应 pop 该页
      case didDeleteRun(UUID)
    }
  }

  @Dependency(\.runsRepository) var runsRepository

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .deleteTapped:
        state.confirmationDialog = ConfirmationDialogState {
          TextState(String(localized: "Delete this run?"))
        } actions: {
          ButtonState(role: .destructive, action: .deleteButtonTapped) {
            TextState(String(localized: "Delete"))
          }
          ButtonState(role: .cancel) {
            TextState(String(localized: "Cancel"))
          }
        }
        return .none

      case .confirmationDialog(.presented(.deleteButtonTapped)):
        state.confirmationDialog = nil
        let id = state.run.id
        return .run { send in
          try? runsRepository.delete(id)
          await send(.delegate(.didDeleteRun(id)))
        }

      case .confirmationDialog:
        state.confirmationDialog = nil
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$confirmationDialog, action: \.confirmationDialog) {
      EmptyReducer()
    }
  }
}
