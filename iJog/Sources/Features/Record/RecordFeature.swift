import Clocks
import ComposableArchitecture
import Foundation

/// 记录页：idle → running ⇄ paused → 保存 → idle
/// running 期间另有自动暂停：持续慢速 → 冻结计时/距离/轨迹（GPS 保持，检测恢复）
@Reducer
struct RecordFeature {
  /// 自动暂停阈值（米/秒）
  enum AutoPause {
    /// 低于此速度视为慢速（≈7.2 km/h，快走以下）
    static let slowSpeed = 2.0
    /// 高于此速度才从自动暂停恢复（≈9 km/h，滞回防抖）
    static let resumeSpeed = 2.5
    /// 持续慢速多少秒后进入自动暂停
    static let confirmSeconds = 10
    /// 自动暂停持续多少秒后自动结束当前跑步
    static let stopAfterPausedSeconds = 300
  }

  @ObservableState
  struct State: Equatable {
    var session = SessionState.idle
    var startedAt: Date?
    var elapsed: TimeInterval = 0
    var distance: Double = 0
    var route: [RoutePoint] = []
    var path = StackState<RunDetailFeature.State>()
    var isLocationDenied = false
    /// 启动时发现的待恢复草稿（弹窗询问恢复/丢弃）
    var pendingDraft: RunDraft?
    @Presents var alert: AlertState<Action.Alert>?

    // MARK: 自动暂停
    /// 开关（默认开，会话内有效）
    var autoPauseEnabled = true
    /// 当前处于自动暂停（慢速排除中）
    var isAutoPaused = false
    /// 最近一次有效 GPS 速度（米/秒）；首次定位前为 nil，不参与慢速判断
    var lastSpeed: Double?
    /// 连续慢速秒数（确认窗口计数）
    var slowSeconds = 0
  }

  enum SessionState: Equatable {
    case idle, running, paused
  }

  enum Action: Equatable {
    case onAppear
    case draftLoaded(RunDraft)
    case startTapped
    case pauseTapped
    case resumeTapped
    case finishTapped
    case toggleAutoPauseTapped
    case timerTicked
    case locationUpdated(point: RoutePoint, speed: Double)
    case saveCompleted(Run)
    case saveFailed
    case alert(PresentationAction<Alert>)
    case path(StackAction<RunDetailFeature.State, RunDetailFeature.Action>)

    @CasePathable
    enum Alert: Equatable {
      case restoreButtonTapped
      case discardButtonTapped
    }
  }

  enum CancelID {
    case timer
    case locations
  }

  @Dependency(\.locationClient) var locationClient
  @Dependency(\.runsRepository) var runsRepository
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date) var date
  @Dependency(\.uuid) var uuid

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        state.isLocationDenied = locationClient.authorizationStatus() == .denied
        // 崩溃/被杀恢复：发现未完成草稿时弹窗询问
        return .run { send in
          if let draft = runsRepository.loadDraft() {
            await send(.draftLoaded(draft))
          }
        }

      case let .draftLoaded(draft):
        state.pendingDraft = draft
        state.alert = AlertState {
          TextState(String(localized: "Unfinished Run Detected"))
        } actions: {
          ButtonState(action: .restoreButtonTapped) {
            TextState(String(localized: "Restore"))
          }
          ButtonState(role: .destructive, action: .discardButtonTapped) {
            TextState(String(localized: "Discard"))
          }
        }
        return .none

      case .startTapped:
        guard state.session == .idle else { return .none }
        state.session = .running
        state.startedAt = date()
        state.elapsed = 0
        state.distance = 0
        state.route = []
        state.isAutoPaused = false
        state.slowSeconds = 0
        state.lastSpeed = nil
        state.pendingDraft = nil
        state.alert = nil
        state.isLocationDenied = locationClient.authorizationStatus() == .denied
        locationClient.requestWhenInUse()
        locationClient.startUpdates()
        // 清掉可能残留的旧草稿
        return .merge(
          checkpointClearEffect,
          trackingEffects
        )

      case .pauseTapped:
        guard state.session == .running else { return .none }
        state.session = .paused
        resetAutoPause(&state)
        locationClient.stopUpdates()
        return .merge(
          checkpointEffect(state), // 暂停边界立即落盘
          .cancel(id: CancelID.timer),
          .cancel(id: CancelID.locations)
        )

      case .resumeTapped:
        guard state.session == .paused else { return .none }
        state.session = .running
        resetAutoPause(&state)
        locationClient.startUpdates()
        return trackingEffects

      case .finishTapped:
        guard state.session != .idle else { return .none }
        return finishAndSaveEffect(&state)

      case .toggleAutoPauseTapped:
        state.autoPauseEnabled.toggle()
        // 关闭时若正处于自动暂停，立即恢复计数
        if !state.autoPauseEnabled {
          state.isAutoPaused = false
          state.slowSeconds = 0
        }
        return .none

      case .timerTicked:
        guard state.session == .running else { return .none }

        // 自动暂停中：累计暂停时长，持续 5 分钟自动结束当前跑步
        if state.isAutoPaused {
          state.slowSeconds += 1
          if state.slowSeconds >= AutoPause.confirmSeconds + AutoPause.stopAfterPausedSeconds {
            return autoStopEffect(&state)
          }
          return .none
        }

        // 持续慢速：不计时，累计确认窗口；满 10 秒进入自动暂停
        if state.autoPauseEnabled,
          let speed = state.lastSpeed,
          speed < AutoPause.slowSpeed
        {
          state.slowSeconds += 1
          if state.slowSeconds >= AutoPause.confirmSeconds {
            state.isAutoPaused = true
          }
          return .none
        }
        state.slowSeconds = 0
        state.elapsed += 1
        // 崩溃保护：每满 10 秒写一次草稿
        if Int(state.elapsed) % 10 == 0 {
          return checkpointEffect(state)
        }
        return .none

      case let .locationUpdated(point, speed):
        guard state.session == .running else { return .none }
        // CLLocation.speed 为 -1 表示无效，沿用上次值
        if speed >= 0 {
          state.lastSpeed = speed
        }

        // 自动暂停中：速度回升到恢复阈值才继续（该点照常累计），否则丢弃
        if state.isAutoPaused {
          guard speed >= AutoPause.resumeSpeed else { return .none }
          state.isAutoPaused = false
          state.slowSeconds = 0
        }

        if let last = state.route.last {
          let delta = haversine(last.coordinate, point.coordinate)
          guard delta >= 2 else { return .none } // 过滤 GPS 静止抖动
          state.distance += delta
        }
        state.route.append(point)
        return .none

      case let .saveCompleted(run):
        reset(&state)
        state.path.append(RunDetailFeature.State(run: run))
        return checkpointClearEffect

      case .saveFailed:
        // 草稿保留在磁盘上，下次启动可恢复
        reset(&state)
        state.alert = AlertState {
          TextState(String(localized: "Save Failed"))
        } message: {
          TextState(
            String(localized: "Sorry, this run could not be saved. It will be restored on next launch.")
          )
        }
        return .none

      case .alert(.presented(.restoreButtonTapped)):
        guard let draft = state.pendingDraft else { return .none }
        state.pendingDraft = nil
        state.startedAt = draft.startedAt
        state.elapsed = draft.elapsed
        state.distance = draft.distance
        state.route = draft.route
        state.session = draft.isPaused ? .paused : .running
        if draft.isPaused {
          return .none
        }
        locationClient.requestWhenInUse()
        locationClient.startUpdates()
        return trackingEffects

      case .alert(.presented(.discardButtonTapped)):
        state.pendingDraft = nil
        return checkpointClearEffect

      case .alert:
        return .none

      case let .path(.element(id: childID, action: .delegate(.didDeleteRun))):
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

  /// 结束当前跑步并保存（手动结束与慢速超时自动结束共用）
  private func finishAndSaveEffect(_ state: inout State) -> Effect<Action> {
    let run = Run(
      id: uuid(),
      startedAt: state.startedAt ?? date(),
      duration: state.elapsed,
      distance: state.distance,
      route: state.route
    )
    state.session = .idle
    locationClient.stopUpdates()
    return .merge(
      .cancel(id: CancelID.timer),
      .cancel(id: CancelID.locations),
      .run { send in
        do {
          try runsRepository.save(run)
          await send(.saveCompleted(run))
        } catch {
          await send(.saveFailed)
        }
      }
    )
  }

  /// 自动暂停超时：有有效轨迹则保存；几乎没动过（不足 2 个轨迹点）则静默丢弃，不生成空记录
  private func autoStopEffect(_ state: inout State) -> Effect<Action> {
    guard state.route.count >= 2 else {
      state.session = .idle
      reset(&state)
      locationClient.stopUpdates()
      return .merge(
        checkpointClearEffect,
        .cancel(id: CancelID.timer),
        .cancel(id: CancelID.locations)
      )
    }
    return finishAndSaveEffect(&state)
  }

  /// 把当前进行中状态写入草稿（fire-and-forget，失败不影响跑步）
  private func checkpointEffect(_ state: State) -> Effect<Action> {
    let draft = RunDraft(
      startedAt: state.startedAt ?? date(),
      elapsed: state.elapsed,
      distance: state.distance,
      route: state.route,
      isPaused: state.session == .paused
    )
    return .run { _ in
      try? runsRepository.saveDraft(draft)
    }
  }

  /// 删除草稿
  private var checkpointClearEffect: Effect<Action> {
    .run { _ in
      runsRepository.clearDraft()
    }
  }

  /// 计时 + 订阅定位流
  private var trackingEffects: Effect<Action> {
    .merge(
      .run { send in
        for await _ in clock.timer(interval: .seconds(1)) {
          await send(.timerTicked)
        }
      }
      .cancellable(id: CancelID.timer),
      .run { send in
        for await location in locationClient.locations() {
          await send(
            .locationUpdated(
              point: RoutePoint(
                lat: location.coordinate.latitude,
                lon: location.coordinate.longitude
              ),
              speed: location.speed
            )
          )
        }
      }
      .cancellable(id: CancelID.locations)
    )
  }

  private func reset(_ state: inout State) {
    state.startedAt = nil
    state.elapsed = 0
    state.distance = 0
    state.route = []
    resetAutoPause(&state)
  }

  private func resetAutoPause(_ state: inout State) {
    state.isAutoPaused = false
    state.slowSeconds = 0
    state.lastSpeed = nil
  }
}
