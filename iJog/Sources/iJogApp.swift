import ComposableArchitecture
import SwiftUI

@main
struct iJogApp: App {
  let store = Store(initialState: AppFeature.State()) {
    AppFeature()
  }

  var body: some Scene {
    WindowGroup {
      AppView(store: store)
    }
  }
}

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    TabView {
      RecordView(store: store.scope(\.record, action: \.record))
        .tabItem { Label("Record", systemImage: "figure.run") }

      HistoryView(store: store.scope(\.history, action: \.history))
        .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
    }
  }
}
