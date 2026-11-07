import Foundation
import AVFoundation

/// Video/audio facts about a media file, loaded with AVFoundation's async API
/// (the synchronous property accessors are deprecated) and exposed synchronously.
public struct AssetInfo {
    public let asset: AVURLAsset
    public let videoTrack: AVAssetTrack?
    public let audioTracks: [AVAssetTrack]
    public let naturalSize: CGSize
    public let transform: CGAffineTransform
    public let duration: Double
    public let fps: Double

    /// Size after the track's preferred transform (what viewers see).
    public var displaySize: CGSize {
        let r = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    public static func load(_ url: URL) throws -> AssetInfo {
        try blocking { try await loadAsync(url) }
    }

    public static func loadAsync(_ url: URL) async throws -> AssetInfo {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var size = CGSize.zero, transform = CGAffineTransform.identity, fps: Float = 0
        if let v = video {
            (size, transform, fps) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        }
        return AssetInfo(asset: asset, videoTrack: video, audioTracks: audio, naturalSize: size, transform: transform,
                         duration: CMTimeGetSeconds(duration), fps: Double(fps > 0 ? fps : 60))
    }
}

final class ResultBox<T>: @unchecked Sendable { var value: Result<T, Error>? }

/// Run async work to completion from synchronous code. The work must not need the main actor.
public func blocking<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.value = .success(try await work()) } catch { box.value = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.value!.get()
}
