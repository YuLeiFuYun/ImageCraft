import Foundation

struct ProgressiveCorpusPixelErrorMetrics: Codable, Equatable {
  let channelCount: Int
  let differentChannelCount: Int
  let maximumAbsoluteError: Int
  let absoluteErrorSum: UInt64
  let squaredErrorSum: UInt64
  let meanAbsoluteErrorMicrounits: UInt64
  let meanSquaredErrorMicrounits: UInt64
  let psnrMicrodecibels: Int64
  let absoluteErrorAtMost8PPM: Int
  let absoluteErrorAtMost16PPM: Int
  let absoluteErrorAtMost32PPM: Int
  let absoluteErrorAtMost64PPM: Int
}

enum ProgressiveCorpusPixelMetricsError: Error {
  case incompatibleBuffers
}

func progressiveCorpusPixelMetrics(
  reference: Data,
  candidate: Data,
) throws -> ProgressiveCorpusPixelErrorMetrics {
  guard reference.count == candidate.count, !reference.isEmpty else {
    throw ProgressiveCorpusPixelMetricsError.incompatibleBuffers
  }
  var different = 0
  var maximum = 0
  var absoluteSum: UInt64 = 0
  var squaredSum: UInt64 = 0
  var atMost8 = 0
  var atMost16 = 0
  var atMost32 = 0
  var atMost64 = 0

  for index in reference.indices {
    let difference = abs(Int(reference[index]) - Int(candidate[index]))
    if difference != 0 {
      different += 1
    }
    maximum = max(maximum, difference)
    absoluteSum += UInt64(difference)
    squaredSum += UInt64(difference * difference)
    if difference <= 8 {
      atMost8 += 1
    }
    if difference <= 16 {
      atMost16 += 1
    }
    if difference <= 32 {
      atMost32 += 1
    }
    if difference <= 64 {
      atMost64 += 1
    }
  }

  let count = UInt64(reference.count)
  let meanAbsoluteMicro = progressiveCorpusScaledRatio(
    absoluteSum,
    multiplier: 1_000_000,
    divisor: count,
  )
  let meanSquaredMicro = progressiveCorpusScaledRatio(
    squaredSum,
    multiplier: 1_000_000,
    divisor: count,
  )
  let mse = Double(squaredSum) / Double(reference.count)
  let psnr = mse == 0 ? 999.0 : 10.0 * log10((255.0 * 255.0) / mse)

  return ProgressiveCorpusPixelErrorMetrics(
    channelCount: reference.count,
    differentChannelCount: different,
    maximumAbsoluteError: maximum,
    absoluteErrorSum: absoluteSum,
    squaredErrorSum: squaredSum,
    meanAbsoluteErrorMicrounits: meanAbsoluteMicro,
    meanSquaredErrorMicrounits: meanSquaredMicro,
    psnrMicrodecibels: Int64((psnr * 1_000_000.0).rounded()),
    absoluteErrorAtMost8PPM: progressiveCorpusFractionPPM(atMost8, denominator: reference.count),
    absoluteErrorAtMost16PPM: progressiveCorpusFractionPPM(atMost16, denominator: reference.count),
    absoluteErrorAtMost32PPM: progressiveCorpusFractionPPM(atMost32, denominator: reference.count),
    absoluteErrorAtMost64PPM: progressiveCorpusFractionPPM(atMost64, denominator: reference.count),
  )
}

func progressiveCorpusFractionPPM(_ numerator: Int, denominator: Int) -> Int {
  guard numerator >= 0, denominator > 0 else { return 0 }
  let product = numerator.multipliedReportingOverflow(by: 1_000_000)
  return product.overflow ? Int.max : min(1_000_000, product.partialValue / denominator)
}

private func progressiveCorpusScaledRatio(
  _ value: UInt64,
  multiplier: UInt64,
  divisor: UInt64,
) -> UInt64 {
  guard divisor > 0 else { return 0 }
  let product = value.multipliedReportingOverflow(by: multiplier)
  return product.overflow ? UInt64.max : product.partialValue / divisor
}
