import UIKit
import AVFoundation

/// 视频首帧缩略图，带内存缓存。MKV 等系统不支持的容器会失败，UI 侧回落到占位图。
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let durationCache = NSCache<NSString, NSNumber>()
    private var inFlight = Set<String>()
    private var pending: [String: [(UIImage?) -> Void]] = [:]
    private let lock = NSLock()

    func cached(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    /// 缓存键必须带尺寸。卡片按 640×360 生成，锁屏封面按 512×512 生成；
    /// 只用 `item.id` 做键时，先到的那张会被另一处直接命中——封面拿到卡片图会糊，
    /// 卡片拿到封面图会被放大。
    private func key(for item: VideoItem, size: CGSize) -> String {
        "\(item.id)@\(Int(size.width))x\(Int(size.height))"
    }

    /// 卡片副标题要显示时长，这里单独缓存一份，避免每张卡都去解析一次 Asset
    func duration(for item: VideoItem) async -> Double? {
        if let hit = durationCache.object(forKey: item.id as NSString) { return hit.doubleValue }
        guard item.systemPlayable else { return nil }
        let asset = AVURLAsset(url: item.url)
        guard let value = try? await asset.load(.duration) else { return nil }
        let seconds = value.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        durationCache.setObject(NSNumber(value: seconds), forKey: item.id as NSString)
        return seconds
    }

    func load(for item: VideoItem, size: CGSize, completion: @escaping (UIImage?) -> Void) {
        let key = key(for: item, size: size)
        if let image = cached(for: key) {
            completion(image)
            return
        }
        lock.lock()
        if inFlight.contains(key) {
            // 已经有人在生成，挂到同一个等待队列，避免重复解码
            pending[key, default: []].append(completion)
            lock.unlock()
            return
        }
        inFlight.insert(key)
        lock.unlock()

        guard item.systemPlayable else {
            lock.lock(); inFlight.remove(key); lock.unlock()
            completion(nil)
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            let image = await Self.makeImage(for: item, size: size)
            guard let self else { return }

            self.lock.lock()
            self.inFlight.remove(key)
            let waiters = self.pending.removeValue(forKey: key) ?? []
            self.lock.unlock()

            if let image {
                self.cache.setObject(image, forKey: key as NSString)
            }
            await MainActor.run {
                completion(image)
                waiters.forEach { $0(image) }
            }
        }
    }

    /// 取帧点：时长的 12%（不早于 3 秒），避开片头的台标 / 广告 / 黑场。
    /// 失败再依次退到 3 秒与首帧，保证任何能解码的文件都有图。
    private static func makeImage(for item: VideoItem, size: CGSize) async -> UIImage? {
        let asset = AVURLAsset(url: item.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

        var seconds: Double = 0
        if let duration = try? await asset.load(.duration) {
            seconds = duration.seconds
        }

        var candidates: [Double] = []
        if seconds.isFinite, seconds > 6 {
            candidates.append(min(max(seconds * 0.12, 3), seconds - 1))
        }
        candidates.append(3)
        candidates.append(0)

        for seconds in candidates {
            let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            if let frame = try? await generator.image(at: time) {
                return UIImage(cgImage: frame.image)
            }
        }
        return nil
    }

    /// 清完要发一条通知：屏幕上已经加载好的卡片不会自己重新取图，
    /// 不重建列表的话「清理缩略图缓存」按下去看起来什么也没发生，
    /// 得重启 App 才会重新生成。
    static let clearedNotification = Notification.Name("thumbnailCacheCleared")

    func clear() {
        cache.removeAllObjects()
        durationCache.removeAllObjects()
        NotificationCenter.default.post(name: Self.clearedNotification, object: nil)
    }
}
