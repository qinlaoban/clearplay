# ClearPlay 开发计划 —— 对标 VidHub 的私人影视库播放器

> 目标：打造一款聚合型影视库播放器。**平台优先级：macOS 优先**，其次 iOS/iPadOS，最后 tvOS/visionOS。
> 核心能力 = **多源聚合 + 自动刮削海报墙 + 专业级播放内核**。

---

## 一、竞品分析（VidHub）

VidHub（Oka Apps 出品）的核心卖点：

| 能力 | 说明 |
|---|---|
| 一站式聚合 | 本地 / SMB(NAS) / WebDAV / 阿里云盘 / 百度网盘 / 115 / OneDrive / Google Drive / Dropbox / Emby / Jellyfin / Plex |
| 自动刮削 | 文件名 → TMDB 匹配，海报墙 + 演员/评分/简介，电视剧分季分集 |
| 全能播放 | MKV/MP4/RMVB/AVI 等，4K HDR / 杜比视界，音轨/字幕切换，倍速，外挂+在线字幕 |
| 云同步 | iCloud 同步媒体库配置、播放进度、收藏 |
| 其他 | 投屏(DLNA/AirPlay)、全局搜索、截图/GIF |

## 二、技术评估（基于现有 ClearPlay 底座）

现有底座：SwiftUI + @Observable + AetherEngine(FFmpeg/VideoToolbox) + 自定义控制条。

### 2.1 各模块技术选型与难度

| 模块 | 方案 | 难度 | 备注 |
|---|---|---|---|
| 播放内核 | ✅ 已有 AetherEngine | 已完成 | 格式/HDR/DV/字幕全覆盖，自带 `IOReader` 自定义字节源 |
| SMB 直连 | AetherEngineSMB（官方可选产品） | ★☆☆ | 无需自研，NTLMv2/guest 支持 |
| WebDAV | 轻量自研（PROPFIND/GET，~300 行）或开源库 | ★★☆ | **重点：接入 Alist/OpenList 后一个协议即覆盖几乎所有国内网盘** |
| 网盘原生 API | 阿里云盘 OpenAPI / 百度网盘开放平台 | ★★★★ | 需企业资质审核、配额限制、政策风险 → 放最后，先用 WebDAV 网关替代 |
| Emby/Jellyfin/Plex | REST API（官方文档齐全） | ★★★ | 直接消费服务器的元数据，**跳过刮削**，体验最好 |
| 刮削 | TMDB API v3（免费申请 key） | ★★☆ | 中文匹配好；需处理国内网络（备用域名/代理）；文件名解析用正则规则集 |
| 媒体库存储 | SwiftData | ★★☆ | MediaItem/Episode/Series/Source 建模，海报图片落盘缓存 |
| 海报墙 UI | SwiftUI LazyVGrid + 图片缓存（自研 NSCache+磁盘 或 Nuke） | ★★☆ | |
| iCloud 同步 | CloudKit（公共数据库不行，用私有库）同步小体积 JSON/记录 | ★★★ | 进度/收藏优先，媒体库配置其次 |
| 在线字幕 | OpenSubtitles API（免费额度）+ opensubtitles 哈希算法 | ★★☆ | |
| AirPlay | 系统免费获得 | ☆ | |
| DLNA/Chromecast | 需自研协议栈 | ★★★★ | 明确砍掉/远期 |
| tvOS 版 | 同一代码加 target + focus engine 适配 | ★★★ | Phase 后期 |

### 2.2 关键架构决策

1. **统一媒体源抽象 `MediaSource` 协议**
   ```swift
   protocol MediaSource {
       func listDirectory(path:) async throws -> [FileEntry]
       func streamURL(for entry:) async throws -> PlaybackSource   // URL 或 IOReader
   }
   ```
   Local/SMB/WebDAV/Alist/Emby 都实现该协议 → 播放层无感知。
   AetherEngine 的 `load(source:)` 接受自定义 `IOReader`，网盘直链可走内存代理。

2. **刮削只做一遍，元数据归一化**
   - 本地/WebDAV/SMB 来源：自己刮削（TMDB）
   - Emby/Jellyfin/Plex 来源：信任服务器元数据，映射到同一 `MediaItem` 模型

3. **网盘策略**：一期不做原生 API，主打「WebDAV + Alist/OpenList」。
   用户自建 OpenList 即可挂阿里/夸克/115/天翼等全部网盘——覆盖 VidHub 90% 场景且零审核风险。

4. **数据流**：
   `Source 扫描 → FileEntry → 文件名解析(标题/年份/季集) → TMDB 匹配 → SwiftData 落库 → 海报墙`

### 2.3 风险清单

| 风险 | 应对 |
|---|---|
| TMDB 国内不可达 | 备用代理域名、允许用户自定义 API 域名 |
| 网盘直链限速/过期 | OpenList 中转模式兜底 |
| App Store 审核（UGC/版权敏感） | 不内置任何源，纯工具属性；避免引导词 |
| 工程量大 | 严格分期，每期可用 |

## 三、开发计划

> 进度速览（2026-08）：Phase 1 已完成（本地库/刮削/海报墙）；Phase 2 的 WebDAV 已完成（SMB 未做）；
> Phase 3 中在线字幕、连播、缩略图预览、iCloud 进度同步已完成；App Intents + Spotlight 已上线。
> iOS target 已随主开发双平台编译验证。

### Phase 1：本地影视库 + 海报墙 ✅
- [x] SwiftData 建模：MediaItem / LibraryFolder / WebDAVServer
- [x] 本地文件夹授权导入（security-scoped bookmark，支持递归扫描）
- [x] 文件名解析器（`Movie.2023.1080p.x264.mkv` / `剧名 S01E02` 正则规则集）
- [x] TMDB 刮削服务（搜索匹配 + 海报/背景图/简介/评分缓存）
- [x] 海报墙 UI：电影网格 + 详情页 + 继续观看横滑区
- [x] 电视剧分季分集展示

### Phase 2：网络来源
- [ ] MediaSource 协议抽象 + 来源管理设置页
- [ ] SMB（AetherEngineSMB）：浏览 + 扫描入库 + 远程流播
- [x] WebDAV：浏览 + 扫描入库 + 远程流播（兼容 Alist/OpenList，网盘用户主路径）
- [x] 远程文件的缩略图/时长探测（FrameExtractor）
- [ ] 弱网优化：起播探针预算（probesize）、缓冲策略

### Phase 3：观影体验完善
- [x] CloudKit 同步：播放进度（收藏/来源配置待做）
- [x] 「继续观看」跨设备接力
- [x] 在线字幕搜索下载（OpenSubtitles，含本地 sidecar 自动挂载）
- [ ] 字幕样式设置（位置/颜色/描边/背景）
- [x] 自动连播下一集（片头跳过待做）
- [x] 全局搜索（库内搜索 + Spotlight/App Intents）

### Phase 4：媒体服务器
- [ ] Emby/Jellyfin 接入（登录、媒体库浏览、元数据直读、已看状态回写）
- [ ] Plex 接入
- [ ] 统一「全部影视」混合视图 + 来源筛选

### Phase 5：扩展平台与远期
- [ ] iOS/iPadOS target（复用同一代码库）
- [ ] tvOS target（焦点引擎适配、大屏海报墙）
- [ ] visionOS（AetherEngine 原生支持）
- [ ] 阿里云盘/百度网盘原生 API（视政策与资质）
- [ ] 截图/GIF、视频调色、音频均衡器
- [ ] DLNA 投屏（可选）

### 里程碑验收标准
- M1（Phase 1 末）：本地文件夹一键变 Netflix 海报墙，可正常续播
- M2（Phase 2 末）：NAS + OpenList 网盘资源全流程可播
- M3（Phase 3 末）：Mac 上看一半 → 其他设备接着看
- M4（Phase 4 末）：Emby 用户可直接替换 VidHub
