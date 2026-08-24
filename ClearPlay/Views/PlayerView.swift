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
    @State private var pointerOverControls = false
    @State private var isScrubbing = false
    @State private var previewImage: CGImage?
    @State private var previewTask: Task<Void, Never>?
    // 连播（Up Next）
    @State private var upNextItem: VideoItem?
    @State private var upNextCountdown = 8
    @State private var countdownTask: Task<Void, Never>?
    /// 双击快进/快退的瞬时提示（nil 不显示）
    @State private var seekFlash: String?
    @State private var flashTask: Task<Void, Never>?

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

            // 双击左右区域：快退/快进 10 秒（覆盖在画面上、控制条之下）
            seekGestureZones

            // 快进/快退瞬时提示
            if let flash = seekFlash {
                Text(flash)
                    .font(.cpHeading)
                    .foregroundStyle(.white)
                    .padding(20)
                    .background(Circle().fill(.black.opacity(0.55)))
                    .transition(.opacity)
            }

            controlOverlay

            // 连播浮层：当前集播完后倒计时自动播放下一集
            if let next = upNextItem {
                upNextOverlay(next)
            }
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
            countdownTask?.cancel()
            previewTask?.cancel()
            savePosition()
        }
        // 每 5 秒或发生回退时落盘一次播放位置；拖拽进度条时刷新缩略图预览
        .onChange(of: vm.currentTime) { _, newTime in
            if newTime - lastSaved > 5 || newTime < lastSaved - 0.5 {
                savePosition(at: newTime)
            }
            if isScrubbing { schedulePreview() }
        }
        // 播放自然结束：标记看完 + 弹出连播提示
        .onChange(of: vm.hasEnded) { _, ended in
            guard ended else { return }
            savePosition(at: vm.duration)
            if let next = library.step(from: item, offset: 1) {
                startUpNextCountdown(next)
            }
        }
        .onChange(of: isScrubbing) { _, scrubbing in
            if scrubbing {
                schedulePreview()
            } else {
                previewTask?.cancel()
                previewImage = nil
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

    // MARK: - 控制层

    /// 双击快进/快退区域（左右各 1/3 屏宽）
    private var seekGestureZones: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { flashSkip(-10) }
            Color.clear.allowsHitTesting(false)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { flashSkip(10) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func flashSkip(_ delta: Double) {
        vm.skip(by: delta)
        flashTask?.cancel()
        seekFlash = delta < 0 ? "−10s" : "+10s"
        flashTask = Task {
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { seekFlash = nil }
        }
    }

    /// 沉浸式控制层：顶栏（返回+片名+全屏）与底部（进度+控制）分开，Material 模糊背景
    private var controlOverlay: some View {
        VStack {
            topBar
            Spacer()
            VStack(spacing: 8) {
                scrubberRow
                controlsRow
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .controlChrome()
            #if os(macOS)
            // 指针停在控制条上时不自动隐藏
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    pointerOverControls = true
                    hideTask?.cancel()
                    controlsVisible = true
                case .ended:
                    pointerOverControls = false
                    if vm.isPlaying { scheduleHide() }
                }
            }
            #endif
        }
        .opacity(controlsVisible ? 1 : 0)
        // 隐藏时禁止命中，避免遮挡下层点击/手势
        .allowsHitTesting(controlsVisible)
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
    }

    /// 顶栏：关闭播放器 + 片名 + 全屏（macOS）
    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                library.current = nil
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("退出播放")

            Text(item.name)
                .font(.cpBodyMed)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

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
        .font(.cpControl)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .controlChrome(top: true)
    }

    /// 进度条 + 时间标签
    private var scrubberRow: some View {
        VStack(spacing: 8) {
            // 拖拽时悬浮预览：缩略图 + 时间气泡
            if isScrubbing {
                VStack(spacing: 6) {
                    if let img = previewImage {
                        Image(img, scale: 1, label: Text("预览"))
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 240, maxHeight: 135)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(radius: 8)
                    }
                    Text(formatTime(vm.currentTime))
                        .font(.cpCaption.monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.cpElevated))
                        .foregroundStyle(.cpText)
                }
                .transition(.opacity)
            }

            HStack(spacing: 12) {
                Text(formatTime(vm.currentTime))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.9))
                    .font(.cpCaption)

                Slider(
                    value: Binding(
                        get: { vm.currentTime },
                        set: { vm.scrubPreview(to: $0) }
                    ),
                    in: 0...max(vm.duration, 0.1)
                ) { editing in
                    isScrubbing = editing
                    if !editing {
                        vm.seek(to: vm.currentTime)
                    }
                }
                .tint(.white)

                Text(formatTime(vm.duration))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.6))
                    .font(.cpCaption)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isScrubbing)
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

            // 键盘上下方向键调音量（隐藏快捷键载体）
            Button {
                vm.volume = min(1, vm.volume + 0.1)
            } label: { EmptyView() }
            .keyboardShortcut(.upArrow, modifiers: [])

            Button {
                vm.volume = max(0, vm.volume - 0.1)
            } label: { EmptyView() }
            .keyboardShortcut(.downArrow, modifiers: [])
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .labelStyle(.iconOnly)
        .font(.cpControl)
    }

    private var playPauseButton: some View {
        Button {
            vm.togglePlayPause()
            revealControls()
        } label: {
            Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                .font(.cpPlay)
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
                .font(.cpSmall)
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

    // MARK: - 缩略图进度预览

    /// 拖拽中防抖拉取目标位置缩略图
    private func schedulePreview() {
        previewTask?.cancel()
        let target = vm.currentTime
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let img = await vm.thumbnail(at: target)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.15)) { previewImage = img }
        }
    }

    // MARK: - 连播（Up Next）

    private func startUpNextCountdown(_ next: VideoItem) {
        upNextItem = next
        upNextCountdown = 8
        countdownTask?.cancel()
        countdownTask = Task {
            while upNextCountdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                upNextCountdown -= 1
            }
            play(next)
        }
    }

    private func cancelUpNext() {
        countdownTask?.cancel()
        upNextItem = nil
    }

    private func play(_ next: VideoItem) {
        countdownTask?.cancel()
        upNextItem = nil
        // 切换 current 触发 PlayerView 重建并加载新条目
        library.current = next
    }

    /// 连播浮层（右上角，不遮挡底部控制条）
    private func upNextOverlay(_ next: VideoItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("接下来播放", systemImage: "play.rectangle.on.rectangle")
                .font(.cpCaption)
                .foregroundStyle(.white.opacity(0.7))

            Text(next.name)
                .font(.cpBodyMed)
                .foregroundStyle(.white)
                .lineLimit(2)

            HStack(spacing: 10) {
                Button {
                    play(next)
                } label: {
                    Text("立即播放 (\(upNextCountdown))")
                        .font(.cpSmall)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(0.9)))
                        .foregroundStyle(.black)
                }

                Button(action: cancelUpNext) {
                    Text("取消")
                        .font(.cpSmall)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().stroke(.white.opacity(0.5)))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(16)
        .frame(width: 260)
        .background(RoundedRectangle(cornerRadius: CPMetrics.radius).fill(.black.opacity(0.85)))
        .overlay(
            RoundedRectangle(cornerRadius: CPMetrics.radius)
                .stroke(.white.opacity(0.15))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(24)
        .transition(.opacity.combined(with: .move(edge: .top)))
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
        scheduleHide()
    }

    /// 排程 3 秒后自动隐藏；指针停在控制条上或已暂停时取消
    private func scheduleHide() {
        hideTask?.cancel()
        guard vm.isPlaying, !pointerOverControls else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !pointerOverControls else { return }
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

/// 控制层背景：黑色渐变压底 + Material 模糊，比纯黑渐变更有层次
extension View {
    fileprivate func controlChrome(top: Bool = false) -> some View {
        background(
            LinearGradient(
                colors: top
                    ? [.black.opacity(0.55), .black.opacity(0.15), .clear]
                    : [.clear, .black.opacity(0.35), .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .background(.ultraThinMaterial)
        )
        .allowsHitTesting(false)
    }
}
