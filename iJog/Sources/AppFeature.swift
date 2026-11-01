import ComposableArchitecture

/// 根 Feature：记录 / 历史 两个 tab
@Reducer
struct AppFeature {
  @ObservableState
  struct State: Equatable {
    var record = RecordFeature.State()
    var history = HistoryFeature.State()
  }

  enum Action {
    case record(RecordFeature.Action)
    case history(HistoryFeature.Action)
  }

  var body: some ReducerOf<Self> {
    Scope(state: \.record, action: \.record) {
      RecordFeature()
    }
    Scope(state: \.history, action: \.history) {
      HistoryFeature()
    }
  }
}
