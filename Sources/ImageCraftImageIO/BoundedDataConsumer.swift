import CoreGraphics
import Foundation
import ImageCraftCore

/// 写入期有界的 Core Graphics data consumer。
///
/// 一次回调若会越过预算，consumer 不写入任何部分字节并返回 0。该策略保证内存中
/// 已接受的数据永远不超过 `maximumBytes`，同时让 ImageIO 终止当前 destination。
package final class BoundedDataConsumer {
  private let state: BoundedDataConsumerState
  package let consumer: CGDataConsumer

  package init(maximumBytes: Int) throws {
    precondition(maximumBytes > 0)
    let state = BoundedDataConsumerState(maximumBytes: maximumBytes)
    let retainedInfo = Unmanaged.passRetained(state).toOpaque()
    var callbacks = CGDataConsumerCallbacks(
      putBytes: boundedDataConsumerPutBytes,
      releaseConsumer: boundedDataConsumerRelease
    )
    guard let consumer = CGDataConsumer(info: retainedInfo, cbks: &callbacks) else {
      Unmanaged<BoundedDataConsumerState>.fromOpaque(retainedInfo).release()
      throw ImageEncodingError.encodeFailed
    }
    self.state = state
    self.consumer = consumer
  }

  package var snapshot: BoundedDataConsumerSnapshot { state.snapshot }

  /// 使用与 C callback 相同的写入路径验证边界代数。
  package func consumeForTesting(_ data: Data) -> Int {
    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return 0 }
      return state.putBytes(baseAddress, count: bytes.count)
    }
  }
}

package struct BoundedDataConsumerSnapshot: Equatable, Sendable {
  package let data: Data
  package let maximumBytes: Int
  package let maximumObservedByteCount: Int
  package let didRejectWrite: Bool

  package init(
    data: Data,
    maximumBytes: Int,
    maximumObservedByteCount: Int,
    didRejectWrite: Bool
  ) {
    self.data = data
    self.maximumBytes = maximumBytes
    self.maximumObservedByteCount = maximumObservedByteCount
    self.didRejectWrite = didRejectWrite
  }
}

private final class BoundedDataConsumerState {
  private let maximumBytes: Int
  private let lock = NSLock()
  private var data = Data()
  private var maximumObservedByteCount = 0
  private var didRejectWrite = false

  init(maximumBytes: Int) {
    self.maximumBytes = maximumBytes
    data.reserveCapacity(min(maximumBytes, 64 * 1024))
  }

  func putBytes(_ buffer: UnsafeRawPointer, count: Int) -> Int {
    lock.lock()
    defer { lock.unlock() }
    guard count > 0 else { return 0 }
    guard !didRejectWrite else { return 0 }
    let remaining = maximumBytes - data.count
    guard count <= remaining else {
      didRejectWrite = true
      return 0
    }
    data.append(buffer.assumingMemoryBound(to: UInt8.self), count: count)
    maximumObservedByteCount = max(maximumObservedByteCount, data.count)
    return count
  }

  var snapshot: BoundedDataConsumerSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return BoundedDataConsumerSnapshot(
      data: data,
      maximumBytes: maximumBytes,
      maximumObservedByteCount: maximumObservedByteCount,
      didRejectWrite: didRejectWrite
    )
  }
}

private func boundedDataConsumerPutBytes(
  _ info: UnsafeMutableRawPointer?,
  _ buffer: UnsafeRawPointer,
  _ count: Int
) -> Int {
  guard let info else { return 0 }
  let state = Unmanaged<BoundedDataConsumerState>.fromOpaque(info).takeUnretainedValue()
  return state.putBytes(buffer, count: count)
}

private func boundedDataConsumerRelease(_ info: UnsafeMutableRawPointer?) {
  guard let info else { return }
  Unmanaged<BoundedDataConsumerState>.fromOpaque(info).release()
}
