import SwiftUI
import AVKit
import AetherEngine

/// 播放器界面：AetherEngine 渲染画面 + 自定义控制条
struct PlayerView: View {
    let item: VideoItem
    let library: LibraryViewModel

    @State private var vm = PlayerViewModel()
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var lastSaved: Double = 0
    @State private var showSubtitleSearch = false

    private func savePosition(at seconds: Double? = nil) {
        let t = seconds ?? vm.currentTime
        guard t > 0 else { return }
        lastSaved = t
        library.savePosition(for: item, seconds: t)
    }

    var body: some View {
        ZStack {
            Color.black

            if let engine = vm.engine {
                AetherPlayerSurface(engine: engine)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            // 解码失败/加载失败提示
            if let error = vm.playbackError {
                ContentUnavailableView {
                    Label("无法播放", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
                .frame(maxWidth: 420)
            }

            controlOverlay
        }
        #if os(macOS)
        .navigationTitle(item.name)
        .onContinuousHover { phase in
            // 鼠标移动时显示控制条
            if case .active = phase { revealControls() }
        }
        #else
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .contentShape(Rectangle())
        .onTapGesture { revealControls(toggleIfVisible: true) }
        .task(id: item.id) {
            vm.load(url: item.url, startPosition: library.resumePosition(for: item))
        }
        .onDisappear {
            hideTask?.cancel()
            savePosition()
        }
        // 每 5 秒或发生回退时落盘一次播放位置
        .onChange(of: vm.currentTime) { _, newTime in
            if newTime - lastSaved > 5 || newTime < lastSaved - 0.5 {
                savePosition(at: newTime)
            }
        }
        .sheet(isPresented: $showSubtitleSearch) {
            if let url = vm.currentVideoURL {
                SubtitleSearchSheet(videoURL: url) { localURL, name, language in
                    vm.addSubtitleTrack(url: localURL, name: name, language: language)
                }
            }
        }
    }

    // MARK: - 控制条

    private var controlOverlay: some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                scrubberRow
                controlsRow
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            )
        }
        .opacity(controlsVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
    }

    /// 进度条 + 时间标签
    private var scrubberRow: some View {
        HStack(spacing: 12) {
            Text(formatTime(vm.currentTime))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
                .font(.caption)

            Slider(
                value: Binding(
                    get: { vm.currentTime },
                    set: { vm.scrubPreview(to: $0) }
                ),
                in: 0...max(vm.duration, 0.1)
            ) { editing in
                if !editing {
                    vm.seek(to: vm.currentTime)
                }
            }
            .tint(.white)

            Text(formatTime(vm.duration))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .font(.caption)
        }
    }

    /// 主控制按钮行
    private var controlsRow: some View {
        HStack(spacing: 18) {
            Button {
                library.step(from: item, offset: -1).map { library.current = $0 }
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .disabled(library.index(of: item) == 0)

            Button {
                vm.skip(by: -10)
            } label: {
                Image(systemName: "gobackward.10")
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            playPauseButton
                .keyboardShortcut(.space, modifiers: [])

            Button {
                vm.skip(by: 10)
            } label: {
                Image(systemName: "goforward.10")
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            Button {
                library.step(from: item, offset: 1).map { library.current = $0 }
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .disabled(library.index(of: item) == library.items.count - 1)

            Spacer()

            if vm.audioTracks.count > 1 {
                audioMenu
            }

            if !vm.subtitleTracks.isEmpty {
                subtitleMenu
            } else {
                subtitleSearchButton
            }

            speedMenu

            volumeControl

            if vm.isPIPAvailable {
                Button {
                    vm.togglePIP()
                } label: {
                    Image(systemName: "pip.enter")
                }
                .help("画中画")
            }

            // 关闭播放器（回到海报墙）
            Button {
                library.current = nil
            } label: {
                Image(systemName: "xmark")
            }
            .help("关闭")

            #if os(macOS)
            Button {
                toggleFullscreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("全屏")
            #endif
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .labelStyle(.iconOnly)
        .font(.system(size: 17, weight: .medium))
    }

    private var playPauseButton: some View {
        Button {
            vm.togglePlayPause()
            revealControls()
        } label: {
            Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 24, weight: .semibold))
        }
    }

    /// 音轨选择菜单
    private var audioMenu: some View {
        Menu {
            ForEach(vm.audioTracks, id: \.id) { track in
                Button(trackLabel(track)) {
                    vm.selectAudioTrack(id: track.id)
                }
            }
        } label: {
            Image(systemName: "waveform")
        }
        .foregroundStyle(.white)
        .help("音轨")
    }

    /// 字幕选择菜单
    private var subtitleMenu: some View {
        Menu {
            Button("关闭字幕") {
                vm.clearSubtitles()
            }
            ForEach(vm.subtitleTracks, id: \.id) { track in
                Button(trackLabel(track)) {
                    vm.selectSubtitleTrack(id: track.id)
                }
            }
            Divider()
            subtitleSearchButton
        } label: {
            Image(systemName: "captions.bbox")
        }
        .foregroundStyle(.white)
        .help("字幕")
    }

    /// 打开在线字幕搜索
    private var subtitleSearchButton: some View {
        Button {
            showSubtitleSearch = true
        } label: {
            Label("在线搜索字幕", systemImage: "magnifyingglass")
        }
    }

    private func trackLabel(_ track: TrackInfo) -> String {
        let parts = [track.name, track.language, track.codec].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "未知" : parts.joined(separator: " · ")
    }

    /// 倍速选择菜单
    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                Button(r == 1.0 ? "正常" : "\(r)x") {
                    vm.setRate(Float(r))
                }
            }
        } label: {
            Text(vm.rate == 1.0 ? "倍速" : "\(vm.rate)x")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.white)
    }

    private var volumeControl: some View {
        HStack(spacing: 6) {
            Image(systemName: volumeIcon)
                .font(.system(size: 14))
                .foregroundStyle(.white)
            Slider(value: $vm.volume, in: 0...1)
                .frame(width: 70)
                .tint(.white)
        }
    }

    private var volumeIcon: String {
        switch vm.volume {
        case 0: "speaker.slash.fill"
        case ..<0.5: "speaker.wave.1.fill"
        default: "speaker.wave.2.fill"
        }
    }

    // MARK: - 控制条显隐逻辑

    /// 显示控制条，3 秒后自动隐藏；toggle 为 true 时可见则直接隐藏
    private func revealControls(toggleIfVisible toggle: Bool = false) {
        if toggle && controlsVisible && vm.isPlaying {
            controlsVisible = false
            hideTask?.cancel()
            return
        }
        controlsVisible = true
        hideTask?.cancel()
        guard vm.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { controlsVisible = false }
        }
    }

    #if os(macOS)
    private func toggleFullscreen() {
        guard let window = NSApp.keyWindow else { return }
        window.toggleFullScreen(nil)
    }
    #endif
}
