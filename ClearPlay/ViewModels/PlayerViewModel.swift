import Foundation
import Observation
import Combine
import AVKit
import AetherEngine

/// 播放器视图模型：封装 AetherEngine，桥接 Combine 状态到 @Observable
@MainActor
@Observable
final class PlayerViewModel {
    /// 播放引擎（首次加载时创建）
    private(set) var engine: AetherEngine?

    // 桥接给 UI 的状态
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var playbackError: String?
    var volume: Double = 1.0 {
        didSet { engine?.volume = Float(volume) }
    }
    private(set) var rate: Float = 1.0
    /// 播放自然结束（用于连播判定）
    private(set) var hasEnded = false

    // 轨道
    private(set) var audioTracks: [TrackInfo] = []
    private(set) var subtitleTracks: [TrackInfo] = []
    private(set) var activeAudioTrackID: Int?
    private(set) var activeSubtitleTrackID: Int?

    // 画中画
    private(set) var pipController: AVPictureInPictureController?

    private var cancellables = Set<AnyCancellable>()
    private var loadedURL: URL?
    /// 进度条缩略图预览解码器（跟随当前加载源）
    private var extractor: FrameExtractor?

    /// 加载新的视频源（引擎复用，支持断点续播）
    func load(url: URL, startPosition: Double? = nil) {
        guard loadedURL != url else { return }
        playbackError = nil
        currentTime = 0

        guard let engine else {
            do {
                let e = try AetherEngine()
                engine = e
                bind(engine: e)
            } catch {
                playbackError = "播放器初始化失败：\(error.localizedDescription)"
                return
            }
            Task { await performLoad(url: url, startPosition: startPosition, engine: engine!) }
            return
        }
        Task { await performLoad(url: url, startPosition: startPosition, engine: engine) }
    }

    private func performLoad(url: URL, startPosition: Double?, engine: AetherEngine) async {
        isLoading = true
        hasEnded = false
        // 换源后旧解码器失效，立即释放
        if let old = extractor {
            extractor = nil
            Task { await old.shutdown() }
        }
        do {
            var options = LoadOptions()
            let isRemote = url.scheme == "http" || url.scheme == "https"

            // 外挂字幕：本地文件查同目录；远程文件从 WebDAV 目录下载同名字幕
            let sidecars: [ExternalSubtitleTrack]
            if isRemote {
                if let client = remoteClient(for: url) {
                    sidecars = await RemoteSubtitleFinder.sidecars(for: url, client: client)
                } else {
                    sidecars = []
                }
                // WebDAV 等需要鉴权的源：Authorization 头注入引擎的所有 Range 请求
                options.httpHeaders = RemoteAuthStore.headers(for: url)
            } else {
                sidecars = LocalSubtitleFinder.sidecars(for: url)
            }
            options.externalSubtitles = sidecars

            if let startPosition {
                try await engine.load(url: url, startPosition: startPosition, options: options)
            } else {
                try await engine.load(url: url, options: options)
            }
            loadedURL = url
            setupPiPIfNeeded(engine: engine)

            // 未启用任何字幕时自动激活第一个外挂轨道
            if !sidecars.isEmpty, engine.activeSubtitleTrackIndex == nil,
               let first = engine.subtitleTracks.first(where: { $0.isExternal }) {
                engine.selectSubtitleTrack(index: first.id)
            }
        } catch {
            isLoading = false
            playbackError = error.localizedDescription
        }
    }

    /// 在线搜索下载的字幕即时挂载并激活
    func addSubtitleTrack(url: URL, name: String, language: String?) {
        guard let engine else { return }
        let track = ExternalSubtitleTrack(url: url, name: name, language: language)
        let info = engine.addExternalSubtitleTrack(track)
        engine.selectSubtitleTrack(index: info.id)
    }

    /// 当前播放文件信息（供在线字幕搜索用）
    var currentVideoURL: URL? { loadedURL }

    /// 进度条缩略图预览（关键帧低清解码，失败返回 nil 由 UI 退化为纯时间气泡）
    func thumbnail(at seconds: Double) async -> CGImage? {
        guard let engine else { return nil }
        if extractor == nil { extractor = engine.makeFrameExtractor() }
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        return await extractor?.thumbnail(at: target, maxWidth: 280)
    }

    /// 远程 URL 命中的 WebDAV 客户端（取字幕目录列表用）；非远程或未配置返回 nil
    private func remoteClient(for url: URL) -> WebDAVClient? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        for server in RemoteAuthStore.servers {
            guard let base = server.url,
                  url.absoluteString.hasPrefix(base.absoluteString) else { continue }
            return try? RemoteAuthStore.makeClient(server: server)
        }
        return nil
    }

    /// 订阅引擎与时钟的发布状态
    private func bind(engine: AetherEngine) {
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .loading:
                    isLoading = true
                    isPlaying = false
                case .playing:
                    isLoading = false
                    isPlaying = true
                    hasEnded = false
                case .paused, .seeking:
                    isLoading = false
                    isPlaying = false
                case .error(let message):
                    isLoading = false
                    isPlaying = false
                    playbackError = message
                case .idle, .ended:
                    isLoading = false
                    isPlaying = false
                    if state == .ended { hasEnded = true }
                }
            }
            .store(in: &cancellables)

        engine.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] d in self?.duration = d }
            .store(in: &cancellables)

        // 时钟是独立 ObservableObject，~10Hz 刷新进度条专用
        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in self?.currentTime = t }
            .store(in: &cancellables)

        // 音轨/字幕轨道列表与选中态
        engine.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in self?.audioTracks = tracks }
            .store(in: &cancellables)

        engine.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in self?.subtitleTracks = tracks }
            .store(in: &cancellables)

        engine.$activeAudioTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.activeAudioTrackID = id }
            .store(in: &cancellables)

        engine.$activeSubtitleTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.activeSubtitleTrackID = id }
            .store(in: &cancellables)
    }

    /// 基于引擎的 AVPlayerLayer 创建画中画控制器（软件渲染路线下 layer 为 nil，按钮自动隐藏）
    private func setupPiPIfNeeded(engine: AetherEngine) {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let layer = engine.nativePlayerLayer,
              pipController?.playerLayer !== layer
        else { return }
        pipController = AVPictureInPictureController(playerLayer: layer)
    }

    // MARK: - 控制

    func togglePlayPause() {
        engine?.togglePlayPause()
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        engine?.setRate(newRate)
    }

    /// 拖拽中实时预览时间
    func scrubPreview(to seconds: Double) {
        currentTime = seconds
    }

    func seek(to seconds: Double) {
        guard let engine else { return }
        let target = max(0, min(seconds, duration))
        Task { try? await engine.seek(to: target) }
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    func selectAudioTrack(id: Int) {
        engine?.selectAudioTrack(index: id)
    }

    func selectSubtitleTrack(id: Int?) {
        guard let id else {
            clearSubtitles()
            return
        }
        engine?.selectSubtitleTrack(index: id)
    }

    func clearSubtitles() {
        engine?.clearSubtitle()
    }

    func togglePIP() {
        guard let pip = pipController, pip.isPictureInPicturePossible else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
            engine?.pictureInPictureActive = false
        } else {
            pip.startPictureInPicture()
            engine?.pictureInPictureActive = true
        }
    }

    var isPIPAvailable: Bool {
        pipController != nil
    }
}
