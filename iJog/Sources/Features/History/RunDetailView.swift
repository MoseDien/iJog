import ComposableArchitecture
import MapKit
import SwiftUI

struct RunDetailView: View {
  @Bindable var store: StoreOf<RunDetailFeature>

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        mapView
        statsView
      }
      .padding()
    }
    .navigationTitle(store.run.startedAt.formatted(.dateTime.year().month().day()))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          store.send(.deleteTapped)
        } label: {
          Image(systemName: "trash")
        }
        .tint(.red)
      }
    }
    .confirmationDialog($store.scope(\.confirmationDialog, action: \.confirmationDialog))
  }

  // MARK: - 地图

  private var mapView: some View {
    Map(initialPosition: .region(Self.fittedRegion(for: store.run.route))) {
      if store.run.route.count > 1 {
        MapPolyline(coordinates: store.run.route.displayCoordinates)
          .stroke(
            Color.accentColor,
            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
          )
      }
    }
    .mapControls {
      MapCompass()
    }
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .frame(height: 300)
  }

  /// 根据轨迹计算适配显示范围（渲染坐标，四周留 20% 边距；空轨迹回退到默认区域）
  static func fittedRegion(for route: [RoutePoint]) -> MKCoordinateRegion {
    let display = route.displayCoordinates
    guard let first = display.first else {
      return MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.009),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
      )
    }
    var minLat = first.latitude
    var maxLat = first.latitude
    var minLon = first.longitude
    var maxLon = first.longitude
    for coordinate in display {
      minLat = min(minLat, coordinate.latitude)
      maxLat = max(maxLat, coordinate.latitude)
      minLon = min(minLon, coordinate.longitude)
      maxLon = max(maxLon, coordinate.longitude)
    }
    let spanScale = 1.4
    return MKCoordinateRegion(
      center: CLLocationCoordinate2D(
        latitude: (minLat + maxLat) / 2,
        longitude: (minLon + maxLon) / 2
      ),
      span: MKCoordinateSpan(
        latitudeDelta: max((maxLat - minLat) * spanScale, 0.002),
        longitudeDelta: max((maxLon - minLon) * spanScale, 0.002)
      )
    )
  }

  // MARK: - 统计

  private var statsView: some View {
    VStack(spacing: 12) {
      HStack(spacing: 12) {
        stat(title: "Distance", value: formatDistance(store.run.distance))
        stat(title: "Duration", value: formatDuration(store.run.duration))
        stat(
          title: "Pace",
          value: formatPace(duration: store.run.duration, distance: store.run.distance)
        )
      }
      Text(
        store.run.startedAt.formatted(
          .dateTime.year().month().day().weekday(.wide).hour().minute()
        )
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
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
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
  }
}
