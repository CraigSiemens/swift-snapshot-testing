#if os(iOS) || os(tvOS)
  import UIKit

  extension Diffing where Value == UIImage {
    /// A pixel-diffing strategy for UIImage's which requires a 100% match.
    public static let image = Diffing.image()

    /// A pixel-diffing strategy for UIImage that allows customizing how precise the matching must be.
    ///
    /// - Parameters:
    ///   - precision: The percentage of pixels that must match.
    ///   - perceptualPrecision: The percentage a pixel must match the source pixel to be considered a
    ///     match. 98-99% mimics
    ///     [the precision](http://zschuessler.github.io/DeltaE/learn/#toc-defining-delta-e) of the
    ///     human eye.
    ///   - scale: Scale to use when loading the reference image from disk. If `nil` or the
    ///     `UITraitCollection`s default value of `0.0`, the screens scale is used.
    /// - Returns: A new diffing strategy.
    public static func image(
      precision: Float = 1, perceptualPrecision: Float = 1, scale: CGFloat? = nil
    ) -> Diffing {
      let imageScale: CGFloat
      if let scale = scale, scale != 0.0 {
        imageScale = scale
      } else {
        imageScale = UIScreen.main.scale
      }
      let toData: (UIImage) -> Data = { $0.pngData() ?? emptyImage().pngData()! }
      return .diff(
        toData: toData,
        fromData: { UIImage(data: $0, scale: imageScale)! }
      ) { old, new in
        let imageComparison = ImageComparisonContext(old: old, new: new)
        guard
          let message = compare(
            imageComparison, precision: precision, perceptualPrecision: perceptualPrecision)
        else { return nil }
        let difference = SnapshotTesting.diff(imageComparison)
        let isEmptyImage = new.size == .zero
        let referenceAttachment = DiffAttachment.data(toData(old), name: "reference.png")
        let failureAttachment = DiffAttachment.data(
          toData(isEmptyImage ? emptyImage() : new),
          name: "failure.png"
        )
        let differenceAttachment = DiffAttachment.data(toData(difference), name: "difference.png")
        return (
          message,
          [referenceAttachment, failureAttachment, differenceAttachment]
        )
      }
    }

    /// Used when the image size has no width or no height to generated the default empty image
    private static func emptyImage() -> UIImage {
      let label = UILabel(frame: CGRect(x: 0, y: 0, width: 400, height: 80))
      label.backgroundColor = .red
      label.text =
        "Error: No image could be generated for this view as its size was zero. Please set an explicit size in the test."
      label.textAlignment = .center
      label.numberOfLines = 3
      return label.asImage()
    }
  }

  extension Snapshotting where Value == UIImage, Format == UIImage {
    /// A snapshot strategy for comparing images based on pixel equality.
    public static var image: Snapshotting {
      return .image()
    }

    /// A snapshot strategy for comparing images based on pixel equality.
    ///
    /// - Parameters:
    ///   - precision: The percentage of pixels that must match.
    ///   - perceptualPrecision: The percentage a pixel must match the source pixel to be considered a
    ///     match. 98-99% mimics
    ///     [the precision](http://zschuessler.github.io/DeltaE/learn/#toc-defining-delta-e) of the
    ///     human eye.
    ///   - scale: The scale of the reference image stored on disk.
    public static func image(
      precision: Float = 1, perceptualPrecision: Float = 1, scale: CGFloat? = nil
    ) -> Snapshotting {
      return .init(
        pathExtension: "png",
        diffing: .image(
          precision: precision, perceptualPrecision: perceptualPrecision, scale: scale)
      )
    }
  }

  // remap snapshot & reference to same colorspace
  private let imageContextColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
  private let imageContextBitsPerComponent = 8
  private let imageContextBytesPerPixel = 4

  private struct ImageComparisonContext {
    enum Comparability {
      case comparable(PixelComparableImagePair)
      case incomparable(String)
    }

    let old: UIImage
    let new: UIImage
    let comparability: Comparability

    init(old: UIImage, new: UIImage) {
      self.old = old
      self.new = new
      guard let oldCgImage = old.cgImage else {
        self.comparability = .incomparable("Reference image could not be loaded.")
        return
      }
      guard let newCgImage = new.cgImage else {
        self.comparability = .incomparable("Newly-taken snapshot could not be loaded.")
        return
      }
      guard newCgImage.width != 0, newCgImage.height != 0 else {
        self.comparability = .incomparable("Newly-taken snapshot is empty.")
        return
      }
      guard
        oldCgImage.width == newCgImage.width,
        oldCgImage.height == newCgImage.height
      else {
        self.comparability = .incomparable(
          "Newly-taken snapshot@\(newCgImage.width)x\(newCgImage.height) pixels does not match reference@\(oldCgImage.width)x\(oldCgImage.height) pixels."
        )
        return
      }
      self.comparability = .comparable(
        PixelComparableImagePair(
          oldCgImage: oldCgImage,
          newCgImage: newCgImage
        )
      )
    }
  }

  private final class PixelComparableImagePair {
    let oldCgImage: CGImage
    let newCgImage: CGImage
    var width: Int { self.oldCgImage.width }
    var height: Int { self.oldCgImage.height }

    private(set) lazy var oldBytes: [UInt8]? = {
      var bytes: [UInt8]?
      _ = Self.render(self.oldCgImage, into: &bytes)
      return bytes
    }()
    private(set) lazy var newBytes: [UInt8]? = {
      var bytes: [UInt8]?
      _ = Self.render(self.newCgImage, into: &bytes)
      return bytes
    }()

    init(oldCgImage: CGImage, newCgImage: CGImage) {
      self.oldCgImage = oldCgImage
      self.newCgImage = newCgImage
    }

    func bytesMatch() -> Bool? {
      guard
        let oldBytes = self.oldBytes,
        let newBytes = self.newBytes
      else { return nil }
      return oldBytes.withUnsafeBytes { oldBytes in
        newBytes.withUnsafeBytes { newBytes in
          memcmp(oldBytes.baseAddress, newBytes.baseAddress, oldBytes.count) == 0
        }
      }
    }

    func renderPngEncodedNewImage(_ new: UIImage) -> Bool {
      guard
        let pngData = new.pngData(),
        let newCgImage = UIImage(data: pngData)?.cgImage,
        newCgImage.width == self.width,
        newCgImage.height == self.height
      else {
        self.newBytes = nil
        return false
      }

      return Self.render(newCgImage, into: &self.newBytes)
    }
    
    private static func render(_ cgImage: CGImage, into bytes: inout [UInt8]?) -> Bool {
      guard let colorSpace = imageContextColorSpace else {
        bytes = nil
        return false
      }

      let byteCount = imageContextBytesPerPixel * cgImage.width * cgImage.height
      if bytes?.count != byteCount {
        bytes = [UInt8](repeating: 0, count: byteCount)
      }
      let rendered = bytes!.withUnsafeMutableBytes { bytes in
        guard
          let context = CGContext(
            data: bytes.baseAddress,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: imageContextBitsPerComponent,
            bytesPerRow: cgImage.width * imageContextBytesPerPixel,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
        else { return false }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return true
      }
      if !rendered {
        bytes = nil
      }
      return rendered
    }
  }

  private func compare(
    _ imageComparison: ImageComparisonContext,
    precision: Float,
    perceptualPrecision: Float
  ) -> String?
  {
    let imagePair: PixelComparableImagePair
    switch imageComparison.comparability {
    case let .comparable(comparableImagePair):
      imagePair = comparableImagePair
    case let .incomparable(message):
      return message
    }
    guard imagePair.oldBytes != nil else {
      return "Reference image's data could not be loaded."
    }
    if imagePair.bytesMatch() == true { return nil }
    guard imagePair.renderPngEncodedNewImage(imageComparison.new) else {
      return "Newly-taken snapshot's data could not be loaded."
    }
    if imagePair.bytesMatch() == true { return nil }
    if precision >= 1, perceptualPrecision >= 1 {
      return "Newly-taken snapshot does not match reference."
    }
    if perceptualPrecision < 1, #available(iOS 11.0, tvOS 11.0, *) {
      guard
        let message = perceptuallyCompare(
          CIImage(cgImage: imagePair.oldCgImage),
          CIImage(cgImage: imagePair.newCgImage),
          pixelPrecision: precision,
          perceptualPrecision: perceptualPrecision
        )
      else { return nil }
      return message
    } else {
      guard
        let oldBytes = imagePair.oldBytes,
        let newBytes = imagePair.newBytes
      else {
        return "Newly-taken snapshot's data could not be loaded."
      }
      let byteCount = oldBytes.count
      let byteCountThreshold = Int((1 - precision) * Float(byteCount))
      var differentByteCount = 0
      // NB: We are purposely using a verbose 'while' loop instead of a 'for in' loop.  When the
      //     compiler doesn't have optimizations enabled, like in test targets, a `while` loop is
      //     significantly faster than a `for` loop for iterating through the elements of a memory
      //     buffer. Details can be found in [SR-6983](https://github.com/apple/swift/issues/49531)
      var index = 0
      while index < byteCount {
        defer { index += 1 }
        if oldBytes[index] != newBytes[index] {
          differentByteCount += 1
        }
      }
      if differentByteCount > byteCountThreshold {
        let actualPrecision = 1 - Float(differentByteCount) / Float(byteCount)
        return "Actual image precision \(actualPrecision) is less than required \(precision)"
      }
    }
    return nil
  }

  private func diff(_ imageComparison: ImageComparisonContext) -> UIImage {
    normalizedComponentDiff(imageComparison)
    ?? blendModeDiff(imageComparison.old, imageComparison.new)
  }

  private func blendModeDiff(_ old: UIImage, _ new: UIImage) -> UIImage {
    let width = max(old.size.width, new.size.width)
    let height = max(old.size.height, new.size.height)
    let scale = max(old.scale, new.scale)
    UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: height), true, scale)
    new.draw(at: .zero)
    old.draw(at: .zero, blendMode: .difference, alpha: 1)
    let differenceImage = UIGraphicsGetImageFromCurrentImageContext()!
    UIGraphicsEndImageContext()
    return differenceImage
  }

private func normalizedComponentDiff(_ imageComparison: ImageComparisonContext) -> UIImage? {
  guard
    case let .comparable(imagePair) = imageComparison.comparability,
    let oldBytes = imagePair.oldBytes,
    let newBytes = imagePair.newBytes
  else { return nil }
  let width = imagePair.width
  let height = imagePair.height
  guard let outputColorSpace = CGColorSpace(name: CGColorSpace.linearGray),
        let outputFormat = vImage_CGImageFormat(
          bitsPerComponent: imageContextBitsPerComponent,
          bitsPerPixel: imageContextBitsPerComponent,
          colorSpace: outputColorSpace,
          bitmapInfo: .init()
        )
  else {
    return nil
  }
  
  let pixelCount = width * height
  let byteCount = pixelCount * imageContextBytesPerPixel
  guard oldBytes.count == byteCount, newBytes.count == byteCount else {
    return nil
  }
  
  var diffBytes = [UInt8](repeating: 0, count: pixelCount)
  
  var index = 0
  while index < pixelCount {
    defer { index += 1 }
    let pixelOffset = index * imageContextBytesPerPixel
    
    let rOld = Int16(oldBytes[pixelOffset])
    let gOld = Int16(oldBytes[pixelOffset + 1])
    let bOld = Int16(oldBytes[pixelOffset + 2])
    let aOld = Int16(oldBytes[pixelOffset + 3])
    
    let rNew = Int16(newBytes[pixelOffset])
    let gNew = Int16(newBytes[pixelOffset + 1])
    let bNew = Int16(newBytes[pixelOffset + 2])
    let aNew = Int16(newBytes[pixelOffset + 3])
    
    let rDiff = abs(rOld - rNew)
    let gDiff = abs(gOld - gNew)
    let bDiff = abs(bOld - bNew)
    let aDiff = abs(aOld - aNew)
    
    let maxDiff = max(rDiff, gDiff, bDiff, aDiff)
    diffBytes[index] = UInt8(maxDiff)
  }
  
  let outputCgImage: CGImage? = diffBytes.withUnsafeMutableBytes { diffPtr in
    var diffBuffer = vImage_Buffer(
      data: diffPtr.baseAddress,
      height: vImagePixelCount(height),
      width: vImagePixelCount(width),
      rowBytes: width
    )
    
    do {
      var normalizedBuffer = try vImage_Buffer(
        width: width,
        height: height,
        bitsPerPixel: UInt32(imageContextBitsPerComponent)
      )
      defer { normalizedBuffer.free() }
      
      let error = vImageContrastStretch_Planar8(
        &diffBuffer,
        &normalizedBuffer,
        vImage_Flags(kvImageNoFlags)
      )
      
      let buffer = error == kvImageNoError ? normalizedBuffer : diffBuffer
      
      return try buffer.createCGImage(format: outputFormat)
    } catch {
      return nil
    }
  }
  
  guard let outputCgImage else { return nil }
  
  return UIImage(cgImage: outputCgImage, scale: imageComparison.old.scale, orientation: .up)
}
#endif

#if os(iOS) || os(tvOS) || os(macOS)
  import Accelerate.vImage
  import CoreImage.CIKernel
  import MetalPerformanceShaders

  @available(iOS 10.0, tvOS 10.0, macOS 10.13, *)
  func perceptuallyCompare(
    _ old: CIImage, _ new: CIImage, pixelPrecision: Float, perceptualPrecision: Float
  ) -> String? {
    // Calculate the deltaE values. Each pixel is a value between 0-100.
    // 0 means no difference, 100 means completely opposite.
    let deltaOutputImage = old.applyingLabDeltaE(new)
    // Setting the working color space and output color space to NSNull disables color management. This is appropriate when the output
    // of the operations is computational instead of an image intended to be displayed.
    let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    let deltaThreshold = (1 - perceptualPrecision) * 100
    let actualPixelPrecision: Float
    var maximumDeltaE: Float = 0

    // Metal is supported by all iOS/tvOS devices (2013 models or later) and Macs (2012 models or later).
    // Older devices do not support iOS/tvOS 13 and macOS 10.15 which are the minimum versions of swift-snapshot-testing.
    // However, some virtualized hardware do not have GPUs and therefore do not support Metal.
    // In this case, macOS falls back to a CPU-based OpenGL ES renderer that silently fails when a Metal command is issued.
    // We need to check for Metal device support and fallback to CPU based vImage buffer iteration.
    if ThresholdImageProcessorKernel.isSupported {
      // Fast path - Metal processing
      guard
        let thresholdOutputImage = try? deltaOutputImage.applyingThreshold(deltaThreshold),
        let averagePixel = thresholdOutputImage.applyingAreaAverage().renderSingleValue(in: context)
      else {
        return "Newly-taken snapshot's data could not be processed."
      }
      actualPixelPrecision = 1 - averagePixel
      if actualPixelPrecision < pixelPrecision {
        maximumDeltaE = deltaOutputImage.applyingAreaMaximum().renderSingleValue(in: context) ?? 0
      }
    } else {
      // Slow path - CPU based vImage buffer iteration
      guard let buffer = deltaOutputImage.render(in: context) else {
        return "Newly-taken snapshot could not be processed."
      }
      defer { buffer.free() }
      var failingPixelCount: Int = 0
      // rowBytes must be a multiple of 8, so vImage_Buffer pads the end of each row with bytes to meet the multiple of 0 requirement.
      // We must do 2D iteration of the vImage_Buffer in order to avoid loading the padding garbage bytes at the end of each row.
      //
      // NB: We are purposely using a verbose 'while' loop instead of a 'for in' loop.  When the
      //     compiler doesn't have optimizations enabled, like in test targets, a `while` loop is
      //     significantly faster than a `for` loop for iterating through the elements of a memory
      //     buffer. Details can be found in [SR-6983](https://github.com/apple/swift/issues/49531)
      let componentStride = MemoryLayout<Float>.stride
      var line = 0
      while line < buffer.height {
        defer { line += 1 }
        let lineOffset = buffer.rowBytes * line
        var column = 0
        while column < buffer.width {
          defer { column += 1 }
          let byteOffset = lineOffset + column * componentStride
          let deltaE = buffer.data.load(fromByteOffset: byteOffset, as: Float.self)
          if deltaE > deltaThreshold {
            failingPixelCount += 1
            if deltaE > maximumDeltaE {
              maximumDeltaE = deltaE
            }
          }
        }
      }
      let failingPixelPercent =
        Float(failingPixelCount)
        / Float(deltaOutputImage.extent.width * deltaOutputImage.extent.height)
      actualPixelPrecision = 1 - failingPixelPercent
    }

    guard actualPixelPrecision < pixelPrecision else { return nil }
    // The actual perceptual precision is the perceptual precision of the pixel with the highest DeltaE.
    // DeltaE is in a 0-100 scale, so we need to divide by 100 to transform it to a percentage.
    let minimumPerceptualPrecision = 1 - min(maximumDeltaE / 100, 1)
    return """
      The percentage of pixels that match \(actualPixelPrecision) is less than required \(pixelPrecision)
      The lowest perceptual color precision \(minimumPerceptualPrecision) is less than required \(perceptualPrecision)
      """
  }

  extension CIImage {
    func applyingLabDeltaE(_ other: CIImage) -> CIImage {
      applyingFilter("CILabDeltaE", parameters: ["inputImage2": other])
    }

    func applyingThreshold(_ threshold: Float) throws -> CIImage {
      try ThresholdImageProcessorKernel.apply(
        withExtent: extent,
        inputs: [self],
        arguments: [ThresholdImageProcessorKernel.inputThresholdKey: threshold]
      )
    }

    func applyingAreaAverage() -> CIImage {
      applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: extent])
    }

    func applyingAreaMaximum() -> CIImage {
      applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: extent])
    }

    func renderSingleValue(in context: CIContext) -> Float? {
      guard let buffer = render(in: context) else { return nil }
      defer { buffer.free() }
      return buffer.data.load(fromByteOffset: 0, as: Float.self)
    }

    func render(in context: CIContext, format: CIFormat = CIFormat.Rh) -> vImage_Buffer? {
      // Some hardware configurations (virtualized CPU renderers) do not support 32-bit float output formats,
      // so use a compatible 16-bit float format and convert the output value to 32-bit floats.
      guard
        var buffer16 = try? vImage_Buffer(
          width: Int(extent.width), height: Int(extent.height), bitsPerPixel: 16)
      else { return nil }
      defer { buffer16.free() }
      context.render(
        self,
        toBitmap: buffer16.data,
        rowBytes: buffer16.rowBytes,
        bounds: extent,
        format: format,
        colorSpace: nil
      )
      guard
        var buffer32 = try? vImage_Buffer(
          width: Int(buffer16.width), height: Int(buffer16.height), bitsPerPixel: 32),
        vImageConvert_Planar16FtoPlanarF(&buffer16, &buffer32, 0) == kvImageNoError
      else { return nil }
      return buffer32
    }
  }

  // Copied from https://developer.apple.com/documentation/coreimage/ciimageprocessorkernel
  @available(iOS 10.0, tvOS 10.0, macOS 10.13, *)
  final class ThresholdImageProcessorKernel: CIImageProcessorKernel {
    static let inputThresholdKey = "thresholdValue"
    static let device = MTLCreateSystemDefaultDevice()

    static var isSupported: Bool {
      guard let device = device else {
        return false
      }
      #if targetEnvironment(simulator)
        guard #available(iOS 14.0, tvOS 14.0, *) else {
          // The MPSSupportsMTLDevice method throws an exception on iOS/tvOS simulators < 14.0
          return false
        }
      #endif
      return MPSSupportsMTLDevice(device)
    }

    override class func process(
      with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
      output: CIImageProcessorOutput
    ) throws {
      guard
        let device = device,
        let commandBuffer = output.metalCommandBuffer,
        let input = inputs?.first,
        let sourceTexture = input.metalTexture,
        let destinationTexture = output.metalTexture,
        let thresholdValue = arguments?[inputThresholdKey] as? Float
      else {
        return
      }

      let threshold = MPSImageThresholdBinary(
        device: device,
        thresholdValue: thresholdValue,
        maximumValue: 1.0,
        linearGrayColorTransform: nil
      )

      threshold.encode(
        commandBuffer: commandBuffer,
        sourceTexture: sourceTexture,
        destinationTexture: destinationTexture
      )
    }
  }
#endif
