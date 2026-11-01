import ComposableArchitecture
import SwiftUI

struct HistoryView: View {
  @Bindable var store: StoreOf<HistoryFeature>

  var body: some View {
    NavigationStack(path: $store.scope(\.path, action: \.path)) {
      Group {
        if store.runs.isEmpty {
          ContentUnavailableView {
            Label("No Runs Yet", systemImage: "figure.run")
          } description: {
            Text("Start your first run in the Record tab.")
          }
        } else {
          List {
            ForEach(store.runs) { run in
              NavigationLink(state: RunDetailFeature.State(run: run)) {
                RunRow(run: run)
              }
            }
            .onDelete { store.send(.delete($0)) }
          }
        }
      }
      .navigationTitle("History")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            store.send(.syncTapped)
          } label: {
            if store.isSyncing {
              ProgressView()
            } else {
              Image(systemName: "icloud.and.arrow.up")
            }
          }
          .disabled(store.isSyncing)
          .accessibilityLabel(Text("Sync"))
        }
      }
      .alert($store.scope(\.alert, action: \.alert))
    } destination: { detailStore in
      RunDetailView(store: detailStore)
    }
    .task { await store.send(.onAppear).finish() }
  }
}

private struct RunRow: View {
  let run: Run

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(
        run.startedAt.formatted(
          .dateTime.year().month().day().weekday(.wide).hour().minute()
        )
      )
      .font(.subheadline.weight(.medium))

      HStack(spacing: 24) {
        metric(value: formatDistance(run.distance), label: "Distance", prominent: true)
        metric(value: formatDuration(run.duration), label: "Duration")
        metric(
          value: formatPace(duration: run.duration, distance: run.distance),
          label: "Pace"
        )
      }
    }
    .padding(.vertical, 4)
  }

  private func metric(value: String, label: String, prominent: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(prominent ? .headline : .subheadline)
        .monospacedDigit()
        .foregroundStyle(prominent ? .primary : .secondary)
      Text(label)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }
}
