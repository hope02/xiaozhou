# 笔记功能清单 — 小舟浏览器

## 概述
在现有浏览器（书签、历史、下载、WebDAV 同步）基础上，以**笔记为统一容器**，涵盖用户创作、网页摘录、本地导入三种内容来源，使「小舟」成为集浏览、记录与阅读于一体的工具。

### 核心理念

```
笔记系统（统一处理所有文字内容）
├── 用户创作的笔记    ← Markdown 编辑
├── 网页摘录的笔记    ← 阅读模式 / 保存为笔记
└── 导入的本地文档    ← epub / txt 导入（包括小说）
       └── 共享同一套渲染器、存储、搜索、同步
```

**不分立模块**：小说不单独建 Tab、不单独建数据库、不单独维护同步逻辑。导入的小说只是一种"来源类型为 import 的长笔记"。

---

## 一、数据模型层

### 1.1 笔记模型 (`model/Note.ets`)
| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | `string` | 唯一 ID（UUID） |
| `type` | `NoteType` | 来源类型：`manual` / `web_clip` / `import` |
| `title` | `string` | 标题 |
| `content` | `string` | 正文（Markdown 格式存储） |
| `contentPlain` | `string?` | 纯文本摘要（搜索/列表预览用） |
| `sourceUrl` | `string?` | 来源网页 URL（web_clip 时记录） |
| `sourceTitle` | `string?` | 来源网页标题 |
| `importMeta` | `ImportMeta?` | 导入元信息（import 类型时使用，见 1.2） |
| `tags` | `string[]` | 标签列表，导入小说自动打标签如 `["小说", "文学"]` |
| `folderId` | `string?` | 所属分组 ID |
| `isFavorite` | `boolean` | 是否收藏 |
| `readProgress` | `number` | 阅读进度百分比（长文档/小说用） |
| `scrollPosition` | `string?` | 滚动位置锚点（JSON 序列化，恢复阅读用） |
| `createdAt` | `number` | 创建时间戳 |
| `updatedAt` | `number` | 更新时间戳 |
| `deletedFlag` | `boolean` | 软删除标记（同步用） |

### 1.2 导入元信息 (`ImportMeta`)
| 字段 | 类型 | 说明 |
|------|------|------|
| `originalFileName` | `string` | 原始文件名（如 `三体.txt`） |
| `fileFormat` | `'epub' | 'txt'` | 源文件格式 |
| `chapterCount` | `number` | 章节数（解析后自动检测） |
| `chapters` | `Chapter[]` | 章节列表（标题 + 锚点偏移） |
| `characterCount` | `number` | 总字符数 |
| `coverImage` | `string?` | 封面图片（base64 或路径，epub 提取） |

### 1.3 章节结构 (`Chapter`)
| 字段 | 类型 | 说明 |
|------|------|------|
| `title` | `string` | 章节标题 |
| `anchor` | `string` | 锚点 ID（对应 Markdown heading） |
| `level` | `number` | 标题层级（H1/H2/H3） |

### 1.4 笔记分组模型 (`NoteFolder`)
| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | `string` | 唯一 ID |
| `name` | `string` | 分组名称 |
| `icon` | `string?` | 图标（emoji） |
| `color` | `string?` | 颜色标记 |
| `updatedAt` | `number` | 更新时间戳 |

### 1.5 快照模型 (`NoteSnapshot`)
| 字段 | 类型 | 说明 |
|------|------|------|
| `schemaVersion` | `number` | 数据版本号 |
| `notes` | `Note[]` | 全部笔记 |
| `folders` | `NoteFolder[]` | 全部分组 |

---

## 二、数据存储层

### 2.1 Repository 接口 (`repository/NoteRepository.ets`)
沿用现有仓库模式，定义接口：

- `getSnapshot(): Promise<NoteSnapshot>` — 全量快照（同步用）
- `setSnapshot(snapshot: NoteSnapshot): Promise<void>` — 写入全量快照
- `listNotes(type?: NoteType, includeDeleted?: boolean): Promise<Note[]>` — 可筛选类型
- `listFolders(): Promise<NoteFolder[]>` — 获取分组列表
- `getNoteById(id: string): Promise<Note | null>` — 单条笔记
- `upsertNote(note: Note): Promise<void>` — 创建/更新
- `deleteNote(id: string): Promise<void>` — 软删除
- `hardDeleteNote(id: string): Promise<void>` — 永久删除
- `upsertFolder(folder: NoteFolder): Promise<void>` — 创建/更新分组
- `deleteFolder(id: string): Promise<void>` — 删除分组
- `searchNotes(keyword: string): Promise<Note[]>` — 全量搜索（标题 + 正文）

### 2.2 本地存储实现
**初期**：`@ohos.data.preferences`（与书签/历史一致）
**数据量大时**：迁移到 `@ohos.data.relationalStore`（RDB），特别是导入长篇小说后单条内容可达 MB 级

### 2.3 导入文件缓存
txt/epub 源文件可选择性保留在沙箱目录 `{context.cacheDir}/imports/`，用于重新导出或全文搜索。

---

## 三、笔记功能

### 3.1 笔记列表页
- **入口**：底部导航栏「笔记」Tab
- **统一列表**：用户笔记、网页摘录、导入小说混合展示，通过类型图标区分
- **筛选快捷栏**：全部 / 我的笔记 / 网页摘录 / 导入文档
- **列表展示**：标题 + 摘要 + 类型图标 + 更新时间 + 阅读进度条（小说/长文档）
- **排序方式**：更新时间 / 创建时间 / 标题 / 阅读进度
- **搜索**：搜索框实时过滤标题和正文
- **批量操作**：多选后批量删除、移动分组、添加标签

### 3.2 笔记详情页 — 阅读模式
所有类型笔记共享同一渲染器，但针对不同场景有侧重：

- **Markdown 渲染**：标题、代码块、引用、列表、图片、链接
- **长文档目录导航**：自动提取 H1/H2/H3 生成侧边或顶部目录树，点击跳转。导入小说自动解析章节结构
- **滚动位置记忆**：离开时自动保存，再次打开恢复到上次位置
- **阅读进度**：顶部/底部显示百分比进度，同步到 `readProgress` 字段
- **排版设置**：字号（12-24sp）、行间距（1.2-2.0）、背景色（护眼/羊皮纸/深色）、字体选择
- **阅读模式**：沉浸式全屏，隐藏状态栏和工具栏
- **链接跳转**：笔记内链接可点击跳转浏览器打开

### 3.3 笔记详情页 — 编辑模式（仅 `manual` / `web_clip` 类型）
- **Markdown 编辑器**：源码编辑，带语法高亮
- **快捷工具栏**：Bold / Italic / Heading / Link / Code Block / Quote / List
- **自动保存**：内容变化后 3 秒自动保存
- **预览/编辑**：上下分屏，实时预览渲染效果
- **撤销/重做**：基本编辑历史

> `import` 类型（小说等）默认为只读，但可"转为笔记"复制一份为 `manual` 类型供编辑

### 3.4 快捷笔记
- **浏览器内浮窗**：从浏览器页面快速呼出浮窗记录想法
- **自动关联 URL**：快捷笔记自动记录当前浏览页面地址

---

## 四、本地文档导入

### 4.1 导入方式
- **文件选择器**：通过 `picker.DocumentViewPicker` 选择 `.txt` / `.epub` 文件
- **分享接收**：注册文件类型，支持从系统「分享」接收文件

### 4.2 TXT 导入
- **编码检测**：自动检测 UTF-8 / GBK / GB2312，回退用户手动选择
- **章节分割**：按常见小说章节格式自动分割（第X章 / Chapter X / 空行分隔）
- **大文件处理**：>1MB 的文件分段读取，不阻塞 UI

### 4.3 EPUB 导入
- **解包解析**：解析 `container.xml` → `opf` → 章节顺序
- **HTML→Markdown**：将章节 HTML 转为 Markdown 存储
- **封面提取**：提取封面图片，列表页展示
- **元数据**：提取书名、作者，自动填充标题和标签

### 4.4 导入后行为
- 自动创建 `Note`，`type = 'import'`
- 分组归入默认"导入文档"分组（用户可自行移动）
- 章节信息写入 `importMeta.chapters`，列表页直接显示章节数
- 打开后直接进入阅读模式（只读）

---

## 五、笔记与浏览器集成

### 5.1 网页保存为笔记
- **菜单入口**：浏览器菜单「保存为笔记」
- **保存内容**：标题 + URL + 用户选中的文本（可选）
- **阅读模式提取**：类 Readability 算法提取网页正文，清理广告/侧栏，转为 Markdown

### 5.2 阅读模式
- **入口**：地址栏右侧「阅读模式」图标（页面适合时亮起）
- **功能**：提取正文展示为干净排版，底色护眼，可调节字号
- **可保存**：阅读模式中可直接保存为笔记（`type = web_clip`）

---

## 六、WebDAV 同步

### 6.1 同步架构
复用现有 `WebDavSyncService`，笔记与书签共用同一套同步机制：

```
WebDavSyncService
├── sync()        → 书签同步（现有）
├── syncNotes()   → 笔记同步（新增）
└── syncAll()     → 书签 + 笔记全量同步（新增）
```

### 6.2 配置扩展
在 `WebDavConfig` 中新增：
- `noteRemotePath: string` — 笔记远端路径（默认 `/xiaozhou/notes.json`）
- `syncNotesEnabled: boolean` — 是否开启笔记同步

### 6.3 冲突合并
与书签一致：基于 `updatedAt` 时间戳取较新版本。
导入小说通常一次写入不再修改，冲突概率低。

### 6.4 同步触发
- 手动：笔记列表页「同步」按钮
- 启动：App 启动后自动同步（可配置）
- 变更：笔记变更后延迟自动同步（可配置）

### 6.5 同步范围
- `manual` 和 `web_clip` 类型的笔记全量同步
- `import` 类型笔记**同步元数据但不一定同步全文**（全文可能很大），可在设置中开关

---

## 七、UI 页面结构

### 7.1 文件组织
```
entry/src/main/ets/
├── model/
│   ├── Bookmark.ets
│   ├── Note.ets              ← 新增：Note / NoteFolder / NoteSnapshot / ImportMeta / Chapter
│   ├── WebDavConfig.ets
│   ├── ...
├── repository/
│   ├── NoteRepository.ets        ← 新增：接口
│   ├── PreferencesNoteRepository.ets  ← 新增：Preferences 实现
├── service/
│   ├── WebDavSyncService.ets     ← 扩展：增加笔记同步方法
│   ├── NoteImportService.ets     ← 新增：epub/txt 导入解析服务
├── pages/
│   ├── Index.ets                 ← 现有浏览器主页，增加底部「笔记」Tab
│   ├── NoteListPage.ets          ← 新增：笔记列表
│   ├── NoteDetailPage.ets        ← 新增：阅读 + 编辑二合一
│   ├── NoteSettingsPage.ets      ← 新增：笔记同步等设置
│   ├── ...
```

### 7.2 底部导航（TabBar）
| Tab | 说明 |
|-----|------|
| 浏览器 | 现有浏览器主页 |
| 笔记 | 笔记列表（含导入文档） |
| 书签 | 现有书签 |
| 设置 | 现有设置（含笔记同步配置） |

---

## 八、实施优先级

### Phase 1 — 基础存储（2-3 天）
- [x] 定义 Note / NoteFolder / NoteSnapshot / ImportMeta / Chapter 数据模型
- [x] 实现 NoteRepository 接口
- [x] 实现 PreferencesNoteRepository 本地持久化
- [ ] 单元测试：5 种 CRUD 场景

### Phase 2 — 笔记列表 + 阅读（3-4 天）
- [x] NoteListPage：列表展示、类型筛选、搜索、排序
- [x] 通用 Markdown 渲染组件（正则解析 + 自定义构建）
- [x] NoteDetailPage 阅读模式（排版、字体、深色模式适配）
- [x] 长文档目录导航 + 滚动位置记忆 + 阅读进度
- [x] 底部导航增加「笔记」Tab

### Phase 3 — 笔记编辑 + 快捷笔记（3-4 天）
- [x] Markdown 编辑器 + 快捷工具栏
- [x] 自动保存（3 秒防抖）
- [x] 新建 / 编辑 / 删除笔记
- [x] 分组管理（增删改）
- [x] 标签管理
- [x] 浏览器内快捷笔记浮窗

### Phase 4 — 文档导入（2-3 天）
- [x] 实现 `NoteImportService`：txt 编码检测 + 章节分割
- [x] epub 解析：`@ohos.zlib` 解压 → 目录遍历 → HTML→Markdown → 封面提取（base64）
- [x] 导入 UI：文件选择器 → 导入进度 → 导入完成跳转
- [x] 导入文档列表展示（章节数 + 字数）

### Phase 5 — 浏览器集成（2-3 天）
- [x] 网页「保存为笔记」功能（快捷笔记浮窗 + 当前页面保存）
- [x] 阅读模式 + Readability 正文提取（JavaScript 注入）
- [x] 保存后 Toast 提示跳转

### Phase 6 — WebDAV 同步（2-3 天）
- [x] 扩展 WebDavConfig：noteRemotePath + syncNotesEnabled + syncImportFullContent
- [x] 扩展 WebDavSyncService：syncNotes / syncAll（基于 updatedAt 合并）
- [x] import 类型笔记的同步策略（默认仅同步元数据，可开启全文同步）
- [x] 合并策略：优先保留有全文内容的版本，防止 stripped 覆盖本地全文
- [x] 同步设置 UI（同步面板 + 笔记列表页同步按钮 + 全量同步按钮）
- [x] 同步日志记录笔记同步结果

---

## 九、技术风险与注意事项

1. **Markdown 渲染**：HarmonyOS 无原生 Markdown 组件，需自行解析（可用正则 + SpanString 拼装，或移植轻量解析器）。
2. **大文档性能**：整本小说导入为单条 Note，一次性渲染数千行对 Scroll 性能有压力。方案：虚拟列表 + 分章懒加载。
3. **epub 解析**：HarmonyOS 无现成 epub 库，需自行处理 zip 解压（`@ohos.zlib` 支持）和 XML 解析。
4. **Preferences 容量**：导入大文本后可能触及 ~8MB 上限，需预留 RDB 迁移路径。
5. **同步体积**：全本小说同步会大幅增加 WebDAV 数据量，需在设计上区分元数据同步和全文同步。
