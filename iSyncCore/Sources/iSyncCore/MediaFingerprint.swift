import AVFoundation
import Foundation
import ImageIO

/// What's known about a photo or video's content without reading all of its bytes.
/// Names aren't part of this, because one photo has different IMG_ names on different phones.
public struct MediaFingerprint: Codable, Hashable, Sendable {
    public var size: Int64
    /// Capture time as the camera's local clock showed it, as "yyyyMMddHHmmss".
    public var capture: String?
    /// Sides are stored longest first, because a video's rotation swaps width and height.
    public var longSide: Int?
    public var shortSide: Int?
    /// Photos.sqlite's ZORIGINALSTABLEHASH. It isn't a plain hash of the file, so it only
    /// ever suggests a match. SHA-256 decides.
    public var stableHash: String?

    public init(size: Int64, capture: String? = nil, width: Int? = nil, height: Int? = nil, stableHash: String? = nil) {
        self.size = size
        self.capture = capture
        if let width, let height, width > 0, height > 0 {
            longSide = max(width, height)
            shortSide = min(width, height)
        }
        self.stableHash = stableHash
    }

    /// Capture time plus dimensions, when both are known.
    public var visualKey: String? {
        guard let capture, let longSide, let shortSide else { return nil }
        return "\(capture)|\(longSide)x\(shortSide)"
    }

    /// Whether two same-sized files could be the same bytes. Anything unknown on either
    /// side doesn't rule a match out, because SHA-256 makes the final call.
    func couldBeSameContent(as other: MediaFingerprint) -> Bool {
        guard size == other.size else { return false }
        if let a = capture, let b = other.capture, a != b { return false }
        if let a = longSide, let b = other.longSide, a != b { return false }
        if let a = shortSide, let b = other.shortSide, a != b { return false }
        return true
    }
}

public enum CaptureDate {
    /// Turns "2026:11:02 19:33:25" or "2026-11-02T19:33:25-0800" into "20261102193325".
    public static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = String(raw.filter(\.isNumber).prefix(14))
        guard digits.count == 14, !digits.hasPrefix("0000") else { return nil }
        return digits
    }
}

/// Reads capture details from a file on this Mac, without decoding the image.
enum LocalMediaReader {
    static let images: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "dng", "tif", "tiff", "webp", "gif"]
    static let videos: Set<String> = ["mov", "mp4", "m4v"]

    static func fingerprint(of url: URL, size: Int64) -> MediaFingerprint {
        let ext = url.pathExtension.lowercased()
        if images.contains(ext) { return image(url, size: size) }
        if videos.contains(ext) { return video(url, size: size) }
        return MediaFingerprint(size: size)
    }

    private static func image(_ url: URL, size: Int64) -> MediaFingerprint {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        else { return MediaFingerprint(size: size) }
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let date = exif?[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff?[kCGImagePropertyTIFFDateTime] as? String
        return MediaFingerprint(
            size: size, capture: CaptureDate.normalize(date),
            width: p[kCGImagePropertyPixelWidth] as? Int, height: p[kCGImagePropertyPixelHeight] as? Int)
    }

    private static func video(_ url: URL, size: Int64) -> MediaFingerprint {
        let result = Locked(MediaFingerprint(size: size))
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let asset = AVURLAsset(url: url)
            let track = try? await asset.loadTracks(withMediaType: .video).first
            let natural = try? await track?.load(.naturalSize)
            let metadata = (try? await asset.load(.metadata)) ?? []
            var date: String?
            if let item = metadata.first(where: { $0.identifier == .quickTimeMetadataCreationDate }) {
                date = try? await item.load(.stringValue)
            }
            if date == nil, let item = try? await asset.load(.creationDate) {
                date = try? await item.load(.stringValue)
            }
            let capture = CaptureDate.normalize(date)
            let print = MediaFingerprint(
                size: size, capture: capture,
                width: natural.map { Int($0.width.rounded()) }, height: natural.map { Int($0.height.rounded()) })
            result.with { $0 = print }
            done.signal()
        }
        done.wait()
        return result.with { $0 }
    }
}
