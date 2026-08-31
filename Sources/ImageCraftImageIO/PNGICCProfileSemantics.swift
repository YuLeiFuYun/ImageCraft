import Foundation

enum PNGICCProfileSemantics {
  static func isRGB(_ profile: Data) -> Bool {
    guard profile.count >= 20 else { return false }
    // ICC header bytes 16...19 are the data colour-space signature. Truecolor PNG sources must
    // carry an RGB profile; accepting GRAY/CMYK/etc. while preserving raw samples would misstate
    // the value's source color authority.
    return profile[16] == 0x52
      && profile[17] == 0x47
      && profile[18] == 0x42
      && profile[19] == 0x20
  }
}
