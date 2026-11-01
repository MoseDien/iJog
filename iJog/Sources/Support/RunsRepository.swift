import ComposableArchitecture
import Foundation

/// 跑步记录存储：每次跑步一个 JSON 文件，位于 Documents/Runs/；
/// 进行中草稿位于 Documents/RunDraft.json（Runs 目录外，避免被 loadRuns 误读）
@DependencyClient
struct RunsRepository {
  var loadRuns: @Sendable () throws -> [Run] = { [] }
  var save: @Sendable (Run) throws -> Void
  var delete: @Sendable (UUID) throws -> Void
  var saveDraft: @Sendable (RunDraft) throws -> Void
  var loadDraft: @Sendable () -> RunDraft? = { nil }
  var clearDraft: @Sendable () -> Void = {}
}

// MARK: - Live 实现

private func runsDirectory() throws -> URL {
  let documents = try FileManager.default.url(
    for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
  )
  let directory = documents.appendingPathComponent("Runs", isDirectory: true)
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

private extension JSONEncoder {
  static var runs: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

private extension JSONDecoder {
  static var runs: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

extension RunsRepository: DependencyKey {
  static let liveValue = Self(
    loadRuns: {
      let directory = try runsDirectory()
      return try FileManager.default
        .contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasSuffix(".json") }
        .map { try JSONDecoder.runs.decode(Run.self, from: Data(contentsOf: directory.appendingPathComponent($0))) }
        .sorted { $0.startedAt > $1.startedAt }
    },
    save: { run in
      let directory = try runsDirectory()
      let data = try JSONEncoder.runs.encode(run)
      try data.write(
        to: directory.appendingPathComponent("\(run.id.uuidString).json"),
        options: .atomic
      )
    },
    delete: { id in
      let path = try runsDirectory().appendingPathComponent("\(id.uuidString).json").path
      if FileManager.default.fileExists(atPath: path) {
        try FileManager.default.removeItem(atPath: path)
      }
    },
    saveDraft: { draft in
      let url = try FileManager.default
        .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        .appendingPathComponent("RunDraft.json")
      let data = try JSONEncoder.runs.encode(draft)
      try data.write(to: url, options: .atomic)
    },
    loadDraft: {
      guard let url = try? FileManager.default.url(
        for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      ) else { return nil }
      let draftURL = url.appendingPathComponent("RunDraft.json")
      guard let data = try? Data(contentsOf: draftURL) else { return nil }
      return try? JSONDecoder.runs.decode(RunDraft.self, from: data)
    },
    clearDraft: {
      guard let url = try? FileManager.default.url(
        for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      ) else { return }
      try? FileManager.default.removeItem(at: url.appendingPathComponent("RunDraft.json"))
    }
  )
}

extension DependencyValues {
  var runsRepository: RunsRepository {
    get { self[RunsRepository.self] }
    set { self[RunsRepository.self] = newValue }
  }
}
