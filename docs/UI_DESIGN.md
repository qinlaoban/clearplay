# ClearPlay 界面设计规范（macOS 优先）

> 基于 ui-ux-pro-max 生成的设计系统，适配 macOS 原生 SwiftUI。
> 风格定位：**暗色沉浸 + 影院级海报墙**，参考 Netflix/Infuse 的信息密度，保留原生 App 的克制。

---

## 一、设计基调

| 维度 | 决策 |
|---|---|
| 明暗模式 | **暗色为主**（观影场景），浅色模式仅做可用性兜底 |
| 视觉重心 | 海报图占绝对主导，UI 元素退后（半透明、低对比） |
| 风格关键词 | 深空蓝黑、靛蓝品牌色、绿色播放 CTA、大图少字 |
| 动效 | 200~300ms 过渡；悬停仅颜色/阴影变化，不做布局位移 |

## 二、色彩令牌（Color Tokens）

```swift
extension Color {
    /// 页面背景：深空黑蓝
    static let cpBackground = Color(hex: 0x0F0F23)
    /// 侧栏/卡片表面：比背景略亮一档
    static let cpSurface    = Color(hex: 0x1A1930)
    /// 卡片悬浮态表面
    static let cpSurfaceHi  = Color(hex: 0x232244)
    /// 品牌主色：靛蓝（选中态、进度条、强调）
    static let cpPrimary    = Color(hex: 0x4338CA)
    /// CTA 绿：播放按钮、已看完标记
    static let cpCTA        = Color(hex: 0x22C55E)
    /// 主文本
    static let cpText       = Color(hex: 0xF8FAFC)
    /// 次要文本（最低对比 #94A3B8，仅用于辅助信息）
    static let cpTextSubtle = Color(hex: 0x94A3B8)
}
```

使用规则：
- 背景层级 `cpBackground < cpSurface < cpSurfaceHi`，禁止跳级混用
- `cpPrimary` 用于选中/进行中状态；`cpCTA` 只给"播放"这一个动作，保持唯一性
- 正文用 `cpText`，次要信息 `cpTextSubtle`，正文对比度 ≥ 4.5:1

## 三、字体（映射到原生）

设计系统推荐的 Righteous/Poppins 为 Web 字体，macOS 原生映射：

| 用途 | 字体样式 |
|---|---|
| 页面大标题 | `.system(size: 28, weight: .bold)` |
| 区块标题（如"继续观看"） | `.system(size: 20, weight: .semibold)` |
| 海报卡标题 | `.system(size: 13, weight: .medium)` 单行截断 |
| 辅助信息（年份/时长/评分） | `.system(size: 11)` + `cpTextSubtle` |
| 播放器时间码 | `.monospacedDigit()` |

## 四、整体布局

```
┌─────────┬──────────────────────────────────────────┐
│ 侧栏     │  内容区                                   │
│         │                                          │
│ 🔍 搜索  │  [继续观看 ────────]                      │
│         │  ┌────┐ ┌────┐ ┌────┐ ┌────┐             │
│ 首页     │  │海报│ │海报│ │海报│ │海报│  ←横滑       │
│ 电影     │  └────┘ └────┘ └────┘ └────┘             │
│ 剧集     │                                          │
│ 收藏     │  [全部电影 ────────]                      │
│         │  ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐      │
│ 来源      │  │海报│ │海报│ │海报│ │海报│ │海报│      │
│  ├本地   │  └────┘ └────┘ └────┘ └────┘ └────┘      │
│  ├NAS   │  ┌────┐ ┌────┐ …                         │
│  └网盘   │                                          │
│ ⚙ 设置   │                                          │
└─────────┴──────────────────────────────────────────┘
```

- 结构：`NavigationSplitView`（侧栏 220pt 固定）+ 内容区
- 导航：SwiftUI `NavigationStack` + `navigationDestination(for:)` 类型安全跳转
- 侧栏分区：功能区（搜索/首页/电影/剧集/收藏）与来源区（各媒体源树状列表）分组，中间加 Section 分隔

## 五、核心组件

### 5.1 PosterCard（海报卡）
- 尺寸：2:3 竖版海报，宽 150pt（网格自适应缩放，间距 16pt）
- 圆角 8pt；未刮削成功时显示文件名首字母 + `cpSurface` 占位
- 底部信息两行：标题（1 行截断）+ 年份·时长（subtle）
- 进度条：看过的在海报底部叠 3pt 高进度条，`cpPrimary`
- **悬停（macOS）**：`cpSurface → cpSurfaceHi` 背景 + 阴影加深 + 播放按钮浮现（居中圆形 `cpCTA`）；200ms ease-in-out；**不缩放不位移**
- **点击行为**：单击 = 详情页；悬停出现的播放钮 = 直接续播（触屏设备无 hover，单击进详情，详情页内提供大播放键）

### 5.2 ContinueWatchingRow（继续观看）
- 横滑 `ScrollView(.horizontal)`，卡片改为 16:9 缩略图 + 剩余时间角标
- 数据源：PlayRecord 中 position > 60s 且未播完的条目，按最近播放排序

### 5.3 DetailView（详情页）
- 顶部：全宽背景图（海报 backdrop）+ 底部渐变压黑到页面背景
- 信息区：标题 28pt bold、年份/评分/时长 meta 行、简介最多 4 行可展开
- 操作行：▶ 播放（`cpCTA` 大按钮）、+收藏、…更多（重新刮削/显示文件）
- 剧集：季选择器（Picker）+ 分集列表（缩略图 16:9 + 集数标题 + 时长 + 本集进度条）

### 5.4 PlayerView（播放器，已有）
- 保持现有自定义控制条，配色对齐本规范：控制条渐变黑、按钮白、进度条白 + 缓冲段 `cpPrimary`
- 控制条自动隐藏逻辑不变（3s / 鼠标移动唤起）

### 5.5 空状态
- 无媒体库：居中插画式图标（SF Symbol `film.stack`）+ 一句引导 + 「添加文件夹」主按钮（`cpCTA`）
- 刮削中：海报位显示 shimmer 微光动画（唯一允许的装饰性动画）

## 六、动效规范

| 场景 | 参数 |
|---|---|
| 悬停反馈 | 200ms ease-in-out，只变颜色/阴影 |
| 页面切换 | 系统 push，不自定义 |
| 海报加载淡入 | 250ms opacity |
| 控制条显隐 | 250ms ease-in-out（现状保持） |
| 禁止 | 无限循环装饰动画、hover 位移缩放、超过 300ms 的转场 |

## 七、无障碍与细节

- 所有可点元素有明确 hover/focus 态；键盘 Tab 顺序合理（macOS 重点）
- 图标统一 SF Symbols，同区块尺寸一致（17pt 常规 / 24pt 播放主按钮）
- 不用 emoji 当功能图标
- `prefers-reduced-motion` 时关闭 shimmer 与淡入
- 文字对比度：正文 ≥ 4.5:1，`cpTextSubtle` 只用于 11pt 辅助行

## 八、实施清单（对应 Phase 1）

1. `Theme.swift`：色彩令牌 + 字体快捷方式
2. `PosterCard.swift` / `ContinueWatchingRow.swift` / `ShimmerModifier.swift`
3. 重构 `ContentView`：侧栏分组 + 首页（继续观看 + 全部电影网格）
4. 新增 `MediaDetailView`（电影/剧集通用）
5. 播放器配色对齐
