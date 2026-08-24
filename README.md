# ClearPlay

macOS / iOS 原生聚合影视播放器。SwiftUI + SwiftData 构建，播放内核基于 [AetherEngine](https://github.com/superuser404notfound/AetherEngine)（FFmpeg 解封装 + VideoToolbox 硬解 + AVPlayer 兜底），支持 4K HEVC、多音轨、内封/外挂字幕。

## 功能

- **本地媒体库**：文件夹导入（security-scoped bookmark）、递归扫描、文件名解析（SxxExx / DxEx 等）、TMDB 刮削海报与简介
- **海报墙浏览**：首页（继续观看 / 最近添加）、电影 / 剧集 / 收藏网格，搜索 + 排序 + 列表视图切换，剧集季分集详情页
- **全能播放**：倍速、音轨切换、内封字幕、PiP 画中画、macOS 全屏；断点续播；连播 Up Next 自动播下一集
- **外挂与在线字幕**：自动挂载同目录 sidecar 字幕（srt/ass/ssa/vtt，含语言后缀识别）；[OpenSubtitles](https://www.opensubtitles.com) 在线搜索下载
- **WebDAV 流播**：添加服务器 → 浏览目录导入 → 直接流式播放（Range 拖动），远程同名字幕自动下载挂载
- **App Intents + Spotlight**：快捷指令「播放影片」「继续观看」；Spotlight 搜索影片直达播放
- **进度条缩略图预览**：拖拽时显示目标位置画面
- **iCloud 续播同步**：Mac 看一半、iOS 接着看（需签名配置，见下文）

## 系统要求

- macOS 15.0+ / iOS 18.0+
- Xcode 26+
- [xcodegen](https://github.com/yonaskolb/XcodeGen)

## 构建运行

```bash
# 生成工程（新增源文件后需重新执行）
xcodegen generate

open ClearPlay.xcodeproj   # 选择 ClearPlay-macOS 或 ClearPlay-iOS scheme 运行

# 命令行验证
xcodebuild -project ClearPlay.xcodeproj -scheme ClearPlay-macOS -destination 'platform=macOS' build
xcodebuild test -project ClearPlay.xcodeproj -scheme ClearPlayTests -destination 'platform=macOS'
```

### 调试环境变量

启动方案中已预置（可在 scheme 中填写）：

- `CLEARPLAY_TEST_FILE=/path/to.mp4` — 启动自动加载单个文件
- `CLEARPLAY_TEST_FOLDER=/path/to/dir` — 启动自动添加资料库目录

## 配置

应用内设置页配置即可：

| 配置项 | 说明 |
|--------|------|
| TMDB API Key | 海报刮削用，[免费申请](https://www.themoviedb.org/settings/api)，存 UserDefaults |
| OpenSubtitles API Key | 在线字幕搜索，[免费申请](https://www.opensubtitles.com)，存 UserDefaults |
| OpenSubtitles 账号密码 | 字幕文件下载需要，存 Keychain |
| WebDAV 服务器 | 地址/账号/密码，密码存 Keychain |

### 启用 iCloud 续播同步

CloudKit 是受限 entitlement，ad-hoc 签名下挂载会导致崩溃，因此默认关闭：

1. Xcode 中为两个 target 配置签名 Team（Signing & Capabilities）
2. 取消 `project.yml` 中两个 target 的 `entitlements` 配置注释
3. `xcodegen generate` 重新生成并运行

## 工程结构

```
ClearPlay/
├── App/ClearPlayApp.swift        # 入口：容器注入、生命周期桥接
├── Models/
│   ├── MediaItem.swift           # 媒体条目（SwiftData，本地路径或远程 URL）
│   ├── LibraryFolder.swift       # 资料库目录（bookmark）
│   └── WebDAVServer.swift        # WebDAV 服务器配置
├── ViewModels/
│   ├── LibraryViewModel.swift    # 播放队列、续播位置记忆、持久化
│   ├── MediaLibraryViewModel.swift # 目录管理、扫描入库、TMDB 刮削调度
│   └── PlayerViewModel.swift     # AetherEngine 封装、轨道管理、缩略图解码
├── Services/
│   ├── FilenameParser.swift      # 文件名解析（标题/年份/季集号）
│   ├── FolderScanner.swift       # 递归扫描（跳隐藏目录/sample/符号链接）
│   ├── TMDBService.swift         # TMDB 刮削 + 图片缓存
│   ├── SubtitleService.swift     # sidecar 发现 + OpenSubtitles 客户端
│   ├── WebDAVClient.swift        # PROPFIND 列目录 + 鉴权 + 远程字幕
│   ├── SpotlightIndexer.swift    # Spotlight 全量索引重建
│   ├── CloudSyncService.swift    # CloudKit 续播位置双向同步
│   └── AppDatabase.swift         # 共享 ModelContainer + 播放队列规则
├── Intents/MediaIntents.swift    # App Intents（播放影片/继续观看）+ App Shortcuts
└── Views/                        # SwiftUI 视图（暗色沉浸风）
ClearPlayTests/                   # XCTest 单元测试（73 用例）
```

## 技术要点

- **播放内核**：AetherEngine SPM 依赖（LGPL-3.0 + AppStore 例外），`AetherPlayerSurface` SwiftUI 渲染，Combine 状态桥接到 @Observable
- **持久化**：SwiftData（条目/目录/服务器）+ JSON 文件（播放队列与位置）；远程条目 path 存完整 URL
- **鉴权**：Keychain 存密钥（service `com.clearplay.app`）；WebDAV Basic Auth 经 `LoadOptions.httpHeaders` 注入引擎全部 Range 请求
- **字幕**：加载时注册 `LoadOptions.externalSubtitles` 参与原生渲染；在线字幕经 `addExternalSubtitleTrack` 即时挂载
- **Spotlight**：CoreSpotlight 全量域重建，点击结果经 `NSUserActivity` 回跳播放

## Roadmap

见 [docs/DEVELOPMENT_PLAN.md](docs/DEVELOPMENT_PLAN.md)。已完成 P1（本地库+刮削）与 P2 的 WebDAV 部分。后续方向：

- SMB 原生流播（AetherEngineSMB）
- 启动增量重扫、刮削失败自动重试
- Emby/Jellyfin/Plex 接入、tvOS/visionOS target

## License

本项目代码仅供学习交流。FFmpeg 相关组件遵循 LGPL-3.0（含 AppStore 编译例外条款）。
