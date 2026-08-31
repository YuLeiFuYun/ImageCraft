import CoreGraphics
import Foundation
import ImageCraftCore
import ImageIO

struct ImageIOJPEGAnimationFrameSource: Sendable {
  let data: Data
}

enum ImageIOAnimationBacking: Sendable {
  case encoded(source: ImageIOAnimationSourceBox, inspection: EncodedAnimationInspection)
  case ownedAPNG(
    playback: APNGOwnedStraightAlphaPlayback,
    inspection: EncodedAnimationInspection
  )
  case ownedGIF(
    playback: GIFOwnedPlayback,
    inspection: EncodedAnimationInspection
  )
  case jpegSequence(
    frames: [ImageIOJPEGAnimationFrameSource],
    sourceColorProfile: SourceColorProfile,
    embeddedICCProfile: Data?
  )
}

package struct ImageIOAnimationProviderLifecycleSnapshot: Equatable, Sendable {
  package let isCancelled: Bool
  package let activeOperationCount: Int
  package let queuedOperationCount: Int
  package let holdsPreparedBacking: Bool
}

actor ImageIOAnimationFrameProvider: ImageAnimationFrameProviding {
  private var backing: ImageIOAnimationBacking?
  private let metadata: ImageAnimationMetadata
  private let limits: ImageAnimationDecodeLimits
  private let executor: ImageIOAnimationWorkExecutor
  private var isCancelled = false
  private var activeOperationCount = 0
  private var operationWaiters: [CheckedContinuation<Bool, Never>] = []
  private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    backing: ImageIOAnimationBacking,
    metadata: ImageAnimationMetadata,
    limits: ImageAnimationDecodeLimits,
    executor: ImageIOAnimationWorkExecutor = ImageIOAnimationWorkExecutor()
  ) {
    self.backing = backing
    self.metadata = metadata
    self.limits = limits
    self.executor = executor
  }

  func frame(
    at index: Int,
    request: ImageDecodeRequest
  ) async throws -> DecodedAnimationFrame {
    guard metadata.frames.indices.contains(index) else {
      throw ImageCraftError.animationFrameIndexOutOfRange
    }
    let values = try await decodeFrames(
      in: index..<(index + 1),
      request: request,
      prefersCachedFullImage: false
    )
    guard let frame = values.first else { throw ImageCraftError.animationFrameIndexOutOfRange }
    return frame
  }

  func frames(
    in range: Range<Int>,
    request: ImageDecodeRequest
  ) async throws -> [DecodedAnimationFrame] {
    try await decodeFrames(
      in: range,
      request: request,
      prefersCachedFullImage: false
    )
  }

  private func decodeFrames(
    in range: Range<Int>,
    request: ImageDecodeRequest,
    prefersCachedFullImage: Bool
  ) async throws -> [DecodedAnimationFrame] {
    try Task.checkCancellation()
    guard !isCancelled else { throw ImageCraftError.animationSessionCancelled }
    guard !range.isEmpty,
      range.lowerBound >= 0,
      range.upperBound <= metadata.frames.count
    else { throw ImageCraftError.animationFrameIndexOutOfRange }
    guard range.count <= limits.maximumFrameDecodeWindow else {
      throw ImageCraftError.animationDecodeWindowExceeded
    }
    try await acquireOperationSlot()
    defer { finishActiveOperation() }
    guard !isCancelled, let backing else {
      throw ImageCraftError.animationSessionCancelled
    }
    let descriptors = Array(metadata.frames[range])
    let canvasWidth = metadata.canvasWidth
    let canvasHeight = metadata.canvasHeight
    let trackFrameCount = metadata.frames.count
    let limits = limits
    let images = try await executor.run {
      switch backing {
      case .ownedAPNG(let playback, let inspection):
        let bytes: [Data]
        do {
          bytes = try playback.frames(in: range)
        } catch {
          throw APNGOwnedAnimationIntegration.mapFrameError(error)
        }
        return try bytes.map { frameBytes in
          let image = try ImageIOAnimationFrameRenderer.decodeOwnedRGBA(
            premultipliedRGBA: frameBytes,
            inspection: inspection,
            request: request,
            limits: limits.imageLimits
          )
          try AnimationDecodedByteBudget.validate(
            image,
            trackFrameCount: trackFrameCount,
            maximumTimelineDecodedBytes: limits.maximumTimelineDecodedBytes
          )
          return image
        }
      case .ownedGIF(let playback, let inspection):
        let bytes = try playback.frames(in: range)
        return try bytes.map { frameBytes in
          let image = try ImageIOAnimationFrameRenderer.decodeOwnedRGBA(
            premultipliedRGBA: frameBytes,
            inspection: inspection,
            request: request,
            limits: limits.imageLimits
          )
          try AnimationDecodedByteBudget.validate(
            image,
            trackFrameCount: trackFrameCount,
            maximumTimelineDecodedBytes: limits.maximumTimelineDecodedBytes
          )
          return image
        }
      case .encoded(let source, let inspection):
        return try range.map { index in
          let image = try ImageIOAnimationFrameRenderer.decode(
            source: source,
            index: index,
            inspection: inspection,
            request: request,
            limits: limits.imageLimits,
            prefersCachedFullImage: prefersCachedFullImage
          )
          try AnimationDecodedByteBudget.validate(
            image,
            trackFrameCount: trackFrameCount,
            maximumTimelineDecodedBytes: limits.maximumTimelineDecodedBytes
          )
          return image
        }
      case .jpegSequence(let frames, let sourceColorProfile, let embeddedICCProfile):
        return try range.map { index in
          let image = try ImageIOAnimationFrameRenderer.decodeJPEG(
            frame: frames[index],
            sourceColorProfile: sourceColorProfile,
            embeddedICCProfile: embeddedICCProfile,
            request: request,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            limits: limits.imageLimits,
            prefersCachedFullImage: prefersCachedFullImage
          )
          try AnimationDecodedByteBudget.validate(
            image,
            trackFrameCount: trackFrameCount,
            maximumTimelineDecodedBytes: limits.maximumTimelineDecodedBytes
          )
          return image
        }
      }
    }
    guard !isCancelled else { throw ImageCraftError.animationSessionCancelled }
    try Task.checkCancellation()
    return zip(images, descriptors).map { image, descriptor in
      DecodedAnimationFrame(image: image, descriptor: descriptor)
    }
  }

  func cancel() async {
    isCancelled = true
    backing = nil
    let queuedOperations = operationWaiters
    operationWaiters.removeAll(keepingCapacity: false)
    for waiter in queuedOperations {
      waiter.resume(returning: false)
    }
    guard activeOperationCount > 0 else { return }
    await withCheckedContinuation { continuation in
      cancellationWaiters.append(continuation)
    }
  }

  package func lifecycleSnapshot() -> ImageIOAnimationProviderLifecycleSnapshot {
    ImageIOAnimationProviderLifecycleSnapshot(
      isCancelled: isCancelled,
      activeOperationCount: activeOperationCount,
      queuedOperationCount: operationWaiters.count,
      holdsPreparedBacking: backing != nil
    )
  }

  private func acquireOperationSlot() async throws {
    try Task.checkCancellation()
    guard !isCancelled else { throw ImageCraftError.animationSessionCancelled }
    if activeOperationCount == 0 {
      activeOperationCount = 1
      return
    }
    let granted = await withCheckedContinuation { continuation in
      operationWaiters.append(continuation)
    }
    guard granted else { throw ImageCraftError.animationSessionCancelled }
    do {
      try Task.checkCancellation()
    } catch {
      finishActiveOperation()
      throw error
    }
    guard !isCancelled else {
      finishActiveOperation()
      throw ImageCraftError.animationSessionCancelled
    }
  }

  private func finishActiveOperation() {
    precondition(activeOperationCount == 1)
    if isCancelled {
      activeOperationCount = 0
      guard !cancellationWaiters.isEmpty else { return }
      let waiters = cancellationWaiters
      cancellationWaiters.removeAll(keepingCapacity: false)
      for waiter in waiters {
        waiter.resume()
      }
      return
    }
    if !operationWaiters.isEmpty {
      let next = operationWaiters.removeFirst()
      next.resume(returning: true)
      return
    }
    activeOperationCount = 0
  }
}

/// `CGImageSource` is immutable after preparation but Core Foundation does not expose a
/// Sendable conformance. A single lock serializes ImageIO calls while color conversion runs outside it.
final class ImageIOAnimationSourceBox: @unchecked Sendable {
  private let lock = NSLock()
  private let source: CGImageSource

  init(source: CGImageSource) {
    self.source = source
  }

  func image(at index: Int, options: CFDictionary) throws -> CGImage {
    try lock.withLock {
      guard let image = CGImageSourceCreateImageAtIndex(source, index, options) else {
        throw ImageCraftError.decodeFailed
      }
      return image
    }
  }

  func thumbnail(at index: Int, options: CFDictionary) throws -> CGImage {
    try lock.withLock {
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options) else {
        throw ImageCraftError.decodeFailed
      }
      return image
    }
  }
}

final class ImageIOAnimationWorkExecutor: Sendable {
  private let queue = DispatchQueue(
    label: "dev.fovea.imageio.animation",
    qos: .userInitiated,
    attributes: .concurrent,
    autoreleaseFrequency: .workItem
  )
  private let beforeOperation: @Sendable () -> Void

  init(beforeOperation: @escaping @Sendable () -> Void = {}) {
    self.beforeOperation = beforeOperation
  }

  func run<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.beforeOperation()
        continuation.resume(with: Result(catching: operation))
      }
    }
  }
}
