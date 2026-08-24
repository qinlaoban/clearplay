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

    // 轨道
    private(set) var audioTracks: [TrackInfo] = []
    private(set) var subtitleTracks: [TrackInfo] = []
    private(set) var activeAudioTrackID: Int?
    private(set) var activeSubtitleTrackID: Int?

    // 画中画
    private(set) var pipController: AVPictureInPictureController?

    private var cancellables = Set<AnyCancellable>()
    private var loadedURL: URL?

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
        do {
            if let startPosition {
                try await engine.load(url: url, startPosition: startPosition)
            } else {
                try await engine.load(url: url)
            }
            loadedURL = url
            setupPiPIfNeeded(engine: engine)
        } catch {
            isLoading = false
            playbackError = error.localizedDescription
        }
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
