import ComposableArchitecture
import MapKit
import SwiftUI

struct RecordView: View {
  @Bindable var store: StoreOf<RecordFeature>
  @State private var cameraPosition: MapCameraPosition = .userLocation(
    followsHeading: true, fallback: .automatic
  )
  @State private var isConfirmingFinish = false

  var body: some View {
    NavigationStack(path: $store.scope(\.path, action: \.path)) {
      VStack(spacing: 16) {
        statsView
        if store.isAutoPaused {
          autoPauseBadge
        }
        mapView
        controlsView
        if store.isLocationDenied {
          permissionHint
        }
      }
      .padding()
      .animation(.default, value: store.isAutoPaused)
      .navigationTitle("iJog")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button {
              store.send(.toggleAutoPauseTapped)
            } label: {
              if store.autoPauseEnabled {
                Label("Auto Pause", systemImage: "checkmark")
              } else {
                Label("Auto Pause", systemImage: "pause.circle")
              }
            }
          } label: {
            Image(systemName: "gearshape")
          }
        }
      }
      .alert($store.scope(\.alert, action: \.alert))
      .confirmationDialog(
        "End this run?", isPresented: $isConfirmingFinish, titleVisibility: .visible
      ) {
        Button("End & Save", role: .destructive) { store.send(.finishTapped) }
        Button("Keep Running", role: .cancel) {}
      }
      .task { await store.send(.onAppear).finish() }
    } destination: { detailStore in
      RunDetailView(store: detailStore)
    }
  }

  // MARK: - 统计

  private var statsView: some View {
    HStack {
      stat(title: "Duration", value: formatDuration(store.elapsed))
      stat(title: "Distance", value: formatDistance(store.distance))
      stat(
        title: "Pace",
        value: formatPace(duration: store.elapsed, distance: store.distance)
      )
    }
  }

  private func stat(title: String, value: String) -> some View {
    VStack(spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.title2, design: .rounded, weight: .semibold))
        .monospacedDigit()
        .contentTransition(.numericText())
        .animation(.default, value: value)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
    .frame(maxWidth: .infinity)
  }

  /// 自动暂停提示（慢速时段已被排除）
  private var autoPauseBadge: some View {
    Label("Auto-paused (too slow)", systemImage: "pause.circle")
      .font(.footnote.weight(.medium))
      .foregroundStyle(.orange)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(.orange.opacity(0.12), in: Capsule())
      .transition(.opacity)
  }

  // MARK: - 地图

  private var mapView: some View {
    Map(position: $cameraPosition) {
      UserAnnotation()
      if store.route.count > 1 {
        MapPolyline(coordinates: store.route.map(\.coordinate))
          .stroke(
            Color.accentColor,
            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
          )
      }
    }
    .mapControls {
      MapUserLocationButton()
      MapCompass()
    }
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .frame(maxHeight: .infinity)
    .onChange(of: store.session == .running) { _, isRunning in
      if isRunning {
        cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
      }
    }
  }

  // MARK: - 控制

  @ViewBuilder
  private var controlsView: some View {
    switch store.session {
    case .idle:
      Button {
        store.send(.startTapped)
      } label: {
        Label("Start", systemImage: "play.fill")
          .font(.title3.weight(.semibold))
          .frame(maxWidth: .infinity)
      }
      .controlSize(.large)
      .buttonStyle(.borderedProminent)
      .tint(.green)

    case .running:
      controlButtons(
        primaryTitle: "Pause", primaryIcon: "pause.fill", primaryTint: .orange,
        primaryAction: { store.send(.pauseTapped) }
      )

    case .paused:
      controlButtons(
        primaryTitle: "Resume", primaryIcon: "play.fill", primaryTint: .green,
        primaryAction: { store.send(.resumeTapped) }
      )
    }
  }

  private func controlButtons(
    primaryTitle: String,
    primaryIcon: String,
    primaryTint: Color,
    primaryAction: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 12) {
      Button(action: primaryAction) {
        Label(primaryTitle, systemImage: primaryIcon)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(primaryTint)

      Button {
        isConfirmingFinish = true
      } label: {
        Label("Finish", systemImage: "stop.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(.red)
    }
    .controlSize(.large)
  }

  private var permissionHint: some View {
    Label(
      "Location access denied. Please allow iJog to use your location in Settings.",
      systemImage: "location.slash"
    )
    .font(.footnote)
    .foregroundStyle(.secondary)
  }
}
