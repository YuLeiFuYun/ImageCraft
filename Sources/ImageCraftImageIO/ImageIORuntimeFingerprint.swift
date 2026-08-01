import CoreGraphics
import Foundation
import ImageIO

#if canImport(Darwin)
  import Darwin
#endif

/// 可序列化的操作系统版本三元组。
package struct ImageIOOperatingSystemVersion: Codable, Hashable, Sendable {
  package let majorVersion: Int
  package let minorVersion: Int
  package let patchVersion: Int

  package init(majorVersion: Int, minorVersion: Int, patchVersion: Int) {
    self.majorVersion = majorVersion
    self.minorVersion = minorVersion
    self.patchVersion = patchVersion
  }

  fileprivate init(_ version: OperatingSystemVersion) {
    self.init(
      majorVersion: version.majorVersion,
      minorVersion: version.minorVersion,
      patchVersion: version.patchVersion
    )
  }
}

/// ImageIO 行为证据所绑定的运行时环境。
///
/// ImageIO 是系统框架，同一 Swift 包版本在不同 OS build 上可能产生不同编码字节或
/// 解码行为。证据必须携带该指纹，不能只记录 ImageCraft 自身版本。
package struct ImageIORuntimeFingerprint: Codable, Hashable, Sendable {
  package static let currentSchemaVersion: UInt16 = 1

  package let schemaVersion: UInt16
  package let platform: String
  package let operatingSystemVersion: ImageIOOperatingSystemVersion
  package let operatingSystemBuild: String
  package let architecture: String
  package let imageIOBundleVersion: String
  package let imageIOBundleShortVersion: String
  package let coreGraphicsBundleVersion: String

  package init(
    schemaVersion: UInt16 = Self.currentSchemaVersion,
    platform: String,
    operatingSystemVersion: ImageIOOperatingSystemVersion,
    operatingSystemBuild: String,
    architecture: String,
    imageIOBundleVersion: String,
    imageIOBundleShortVersion: String,
    coreGraphicsBundleVersion: String
  ) {
    self.schemaVersion = schemaVersion
    self.platform = platform
    self.operatingSystemVersion = operatingSystemVersion
    self.operatingSystemBuild = operatingSystemBuild
    self.architecture = architecture
    self.imageIOBundleVersion = imageIOBundleVersion
    self.imageIOBundleShortVersion = imageIOBundleShortVersion
    self.coreGraphicsBundleVersion = coreGraphicsBundleVersion
  }

  /// 捕获当前进程实际加载的系统框架与 OS build，而不是编译 SDK 版本。
  package static func capture() -> Self {
    _ = CGImageSourceGetTypeID()
    _ = CGColorSpace.typeID
    let processInfo = ProcessInfo.processInfo
    return ImageIORuntimeFingerprint(
      platform: currentPlatform,
      operatingSystemVersion: ImageIOOperatingSystemVersion(processInfo.operatingSystemVersion),
      operatingSystemBuild: systemBuildVersion() ?? "unknown",
      architecture: currentArchitecture,
      imageIOBundleVersion: bundleValue(
        identifier: "com.apple.ImageIO", key: kCFBundleVersionKey as String),
      imageIOBundleShortVersion: bundleValue(
        identifier: "com.apple.ImageIO", key: "CFBundleShortVersionString"),
      coreGraphicsBundleVersion: bundleValue(
        identifier: "com.apple.CoreGraphics", key: kCFBundleVersionKey as String)
    )
  }

  private static func bundleValue(identifier: String, key: String) -> String {
    guard let value = Bundle(identifier: identifier)?.object(forInfoDictionaryKey: key) else {
      return "unknown"
    }
    return String(describing: value)
  }

  private static var currentPlatform: String {
    #if os(macOS)
      return "macOS"
    #elseif os(iOS)
      return "iOS"
    #elseif os(tvOS)
      return "tvOS"
    #elseif os(watchOS)
      return "watchOS"
    #elseif os(visionOS)
      return "visionOS"
    #else
      return "unknown"
    #endif
  }

  private static var currentArchitecture: String {
    #if arch(arm64)
      return "arm64"
    #elseif arch(x86_64)
      return "x86_64"
    #elseif arch(arm)
      return "arm"
    #elseif arch(i386)
      return "i386"
    #else
      return "unknown"
    #endif
  }

  private static func systemBuildVersion() -> String? {
    #if canImport(Darwin)
      var byteCount = 0
      guard sysctlbyname("kern.osversion", nil, &byteCount, nil, 0) == 0, byteCount > 1 else {
        return nil
      }
      var bytes = [CChar](repeating: 0, count: byteCount)
      guard sysctlbyname("kern.osversion", &bytes, &byteCount, nil, 0) == 0 else {
        return nil
      }
      let terminator = bytes.firstIndex(of: 0) ?? bytes.endIndex
      return String(decoding: bytes[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    #else
      return nil
    #endif
  }
}
