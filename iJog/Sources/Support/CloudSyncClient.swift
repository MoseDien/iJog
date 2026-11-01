import ComposableArchitecture
import Foundation

/// 一次手动同步的结果
struct SyncReport: Equatable {
  var uploaded: Int
  var downloaded: Int
}

/// iCloud 手动同步：本地 Documents/Runs 与 iCloud Drive 容器 Documents/Runs 按文件名（UUID）并集合并。
/// 跑步记录保存后不可变，同名文件内容一致，因此"只补缺失文件"即可，无内容冲突；
/// 删除不参与同步（v1 已知限制）。
@DependencyClient
struct CloudSyncClient {
  /// iCloud 是否可用（用户已登录且容器已就绪）
  var isAvailable: @Sendable () -> Bool = { false }
  /// 执行上传+下载合并，返回计数
  var sync: @Sendable () throws -> SyncReport
}

// MARK: - Live 实现

extension CloudSyncClient: DependencyKey {
  static let liveValue: Self = {
    let fileManager = FileManager.default

    func runFiles(in directory: URL) throws -> [String: URL] {
      guard try FileManager.default.fileExists(atPath: directory.path) else { return [:] }
      return try fileManager
        .contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasSuffix(".json") }
        .reduce(into: [String: URL]()) { files, name in
          files[name] = directory.appendingPathComponent(name)
        }
    }

    return Self(
      isAvailable: {
        // ubiquityIdentityToken 需要在非主线程查询 url 之前判断；token 为 nil 即未登录
        FileManager.default.ubiquityIdentityToken != nil
      },
      sync: {
        // 注意：此闭包在后台执行（url(forUbiquityContainerIdentifier:) 可能阻塞主线程）
        guard let container = fileManager.url(forUbiquityContainerIdentifier: nil) else {
          throw CloudSyncError.iCloudUnavailable
        }
        let cloudRuns = container
          .appendingPathComponent("Documents", isDirectory: true)
          .appendingPathComponent("Runs", isDirectory: true)
        let documents = try fileManager.url(
          for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let localRuns = documents.appendingPathComponent("Runs", isDirectory: true)
        try? fileManager.createDirectory(at: localRuns, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cloudRuns, withIntermediateDirectories: true)

        let local = try runFiles(in: localRuns)
        let cloud = try runFiles(in: cloudRuns)

        var report = SyncReport(uploaded: 0, downloaded: 0)
        // 上传：本地有、云端没有
        for (name, url) in local where cloud[name] == nil {
          try fileManager.copyItem(at: url, to: cloudRuns.appendingPathComponent(name))
          report.uploaded += 1
        }
        // 下载：云端有、本地没有
        for (name, url) in cloud where local[name] == nil {
          try fileManager.copyItem(at: url, to: localRuns.appendingPathComponent(name))
          report.downloaded += 1
        }
        return report
      }
    )
  }()
}

enum CloudSyncError: Error {
  case iCloudUnavailable
}

extension DependencyValues {
  var cloudSyncClient: CloudSyncClient {
    get { self[CloudSyncClient.self] }
    set { self[CloudSyncClient.self] = newValue }
  }
}
