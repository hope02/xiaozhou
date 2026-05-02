import { common, Want } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { url } from '@kit.ArkTS';
import { pasteboard, request } from '@kit.BasicServicesKit';
import { picker, fileUri } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Bookmark } from '../model/Bookmark';
import { BookmarkFolder } from '../model/Bookmark';
import { BookmarkSnapshot } from '../model/Bookmark';
import { HistoryRecord } from '../model/HistoryRecord';
import { SyncLog } from '../model/SyncLog';
import { WebDavConfig } from '../model/WebDavConfig';
import { DownloadRecord } from '../model/DownloadRecord';
import { BookmarkRepository } from '../repository/BookmarkRepository';
import { HistoryRepository } from '../repository/HistoryRepository';
import { PreferencesBookmarkRepository } from '../repository/PreferencesBookmarkRepository';
import { PreferencesHistoryRepository } from '../repository/PreferencesHistoryRepository';
import { WebDavConfigRepository } from '../repository/WebDavConfigRepository';
import { PreferencesWebDavConfigRepository } from '../repository/PreferencesWebDavConfigRepository';
import { SyncLogRepository } from '../repository/SyncLogRepository';
import { PreferencesSyncLogRepository } from '../repository/PreferencesSyncLogRepository';
import { PreferencesDownloadRecordRepository } from '../repository/PreferencesDownloadRecordRepository';
import { ConnectionTestResult, SyncExecutionResult, WebDavSyncService } from '../service/WebDavSyncService';
import { Note } from '../model/Note';
import { NOTE_FOLDER_IDS, PreferencesNoteRepository } from '../repository/PreferencesNoteRepository';

const DEFAULT_URL: string = '';

interface ErrorLike {
  code?: number | string;
  message?: string;
  name?: string;
  stack?: string;
}

interface TitleReceiveEvent {
  title: string;
}

interface DownloadStartEvent {
  url: string;
  userAgent: string;
  contentDisposition: string;
  mimetype: string;
  contentLength: number;
}

// 建议项数据结构
interface SuggestionItem {
  title: string;
  url: string;
  type: 'bookmark' | 'history';  // 区分收藏夹和历史记录
}

// 页签数据结构 - 手机浏览器简洁方案
interface Tab {
  id: string;
  title: string;       // 标题，最多8个字
  url: string;
  favicon: string;
  thumbnail: string;   // 缩略图
  isPinned: boolean;  // 是否置顶
  isPrivate: boolean; // 是否隐私页签
  isSleeping: boolean; // 是否休眠
  lastAccessTime: number; // 最后访问时间
}

@Entry
@Component
struct Index {
  private progressTimer: number | null = null;
  private pendingWebErrorTimer: number | null = null;
  private webController: webview.WebviewController = new webview.WebviewController();
  private addressInputController: TextInputController = new TextInputController();
  private bookmarkRepository: BookmarkRepository | null = null;
  private historyRepository: HistoryRepository | null = null;
  private webDavConfigRepository: WebDavConfigRepository | null = null;
  private syncLogRepository: SyncLogRepository | null = null;
  private webDavSyncService: WebDavSyncService | null = null;
  private downloadRecordRepository: PreferencesDownloadRecordRepository | null = null;

  @State addressInput: string = DEFAULT_URL;
  @State currentUrl: string = DEFAULT_URL;
  @State isLoading: boolean = false;
  @State statusText: string = '';
  @State showMenuPanel: boolean = false;
  @State loadProgress: number = 0;
  @State showBookmarks: boolean = false;
  @State bookmarks: Bookmark[] = [];
  @State bookmarkListVersion: number = 0;  // 用于强制刷新书签列表UI
  @State bookmarkRefreshFlag: boolean = false;  // 书签刷新标记
  @State showBackupPanel: boolean = false;
  @State backupJsonText: string = '';
  @State bookmarkFolderItems: BookmarkFolder[] = [];
  @State bookmarkFolders: string[] = ['全部', '未分类'];
  @State selectedFolderName: string = '全部';
  @State newFolderName: string = '';
  @State editingFolderId: string = '';
  @State editingFolderName: string = '';
  @State selectedFolderIdForEdit: string = '';
  @State editingBookmarkId: string = '';
  @State editingBookmarkTitle: string = '';
  @State editingBookmarkUrl: string = '';
  @State showHistoryPanel: boolean = false;
  @State historyKeyword: string = '';
  @State historyRecords: HistoryRecord[] = [];
  @State showSyncPanel: boolean = false;
  @State syncServerUrl: string = 'https://dav.jianguoyun.com/dav/';
  @State syncUsername: string = '';
  @State syncPassword: string = '';
  @State syncDraftTouched: boolean = false;
  @State syncRemotePath: string = '/小舟/书签/bookmarks.json';
  @State autoSyncOnLaunch: boolean = false;
  @State autoSyncOnChange: boolean = false;
  @State syncImportFullContent: boolean = false;
  @State syncNoteRemotePath: string = '/小舟/笔记';
  @State connectionStatusText: string = '未测试';
  @State connectionStatusType: string = 'neutral';
  @State syncBusy: boolean = false;
  @State syncBusyText: string = '';
  @State syncLogs: SyncLog[] = [];
  @State lastSyncErrorDetail: string = '';
  @State showAddressBar: boolean = true;
  @State addressBarHeight: number = 56;
  @State addressBarVisible: boolean = true;
  @State showSuggestions: boolean = false;
  @State suggestions: SuggestionItem[] = [];
  @State addressInputFocused: boolean = false;
  @State quickAccessItems: SuggestionItem[] = [];  // 智能快捷访问列表
  @State showDownloadPanel: boolean = false;  // 下载管理面板
  @State downloadRecords: DownloadRecord[] = [];  // 下载记录列表
  @State showQuickNote: boolean = false;  // 快捷笔记浮窗
  @State quickNoteTitle: string = '';
  @State quickNoteContent: string = '';
  @State showReadingMode: boolean = false;
  @State readingTitle: string = '';
  @State readingContent: string = '';
  @State readingFontSize: number = 18;
  @State readingBgMode: string = 'paper';
  @State readingLineHeight: number = 1.8;
  @State preferDesktopSite: boolean = false;
  private noteRepo: PreferencesNoteRepository | null = null;
  private navigatingToNotes: boolean = false;
  private touchStartY: number = 0;
  private touchStartX: number = 0;
  private readonly SWIPE_THRESHOLD: number = 30;
  private readonly BACK_SWIPE_THRESHOLD: number = 50;
  private navToastActionId: number = 0;
  private navToastShownForActionId: number = 0;

  // UA: use "desktop site" when enabled.
  private readonly DESKTOP_USER_AGENT: string =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36';
  private readonly MOBILE_USER_AGENT: string =
    'Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Mobile Safari/537.36';

  // 多页签相关状态
  @State tabs: Tab[] = [];  // 所有页签列表
  @State activeTabId: string = '';  // 当前活动页签ID
  @State showTabsPanel: boolean = false;  // 是否显示页签选择面板
  @State closedTabs: Tab[] = [];  // 已关闭页签列表（保留最近10个）
  @State showUndoClose: boolean = false;  // 显示撤销关闭提示
  private sleepTimer: number | null = null;  // 休眠检测定时器
  private readonly MAX_CLOSED_TABS: number = 10;  // 最多保留10个已关闭页签
  private readonly MAX_ACTIVE_TABS: number = 12;  // 最多活跃页签数
  private readonly SLEEP_THRESHOLD: number = 30000;  // 30秒后休眠（毫秒）
  private readonly AUTO_CLOSE_THRESHOLD: number = 3600000;  // 1小时后自动关闭（毫秒）

  aboutToAppear(): void {
    // 初始化下载记录仓库
    try {
      const context = getContext(this) as common.UIAbilityContext;
      this.downloadRecordRepository = new PreferencesDownloadRecordRepository(context);
      this.noteRepo = new PreferencesNoteRepository(context);
      this.loadDownloadRecords();
    } catch (e) {
      console.error('Failed to initialize Index page:', e);
      promptAction.showToast({ message: '初始化失败,请重启应用' });
    }
  }

  // 加载下载记录
  private async loadDownloadRecords(): Promise<void> {
    if (this.downloadRecordRepository) {
      const records = await this.downloadRecordRepository.listRecords();
      this.downloadRecords = records;
    }
  }

  // 保存下载记录
  private async saveDownloadRecords(): Promise<void> {
    if (this.downloadRecordRepository) {
      await this.downloadRecordRepository.clearAll();
      for (const record of this.downloadRecords) {
        await this.downloadRecordRepository.saveRecord(record);
      }
    }
  }

  onPageShow(): void {
    // 从笔记页面返回时重置导航状态
    this.navigatingToNotes = false;
  }

  onBackPress(): boolean {
    // 优先处理面板关闭（系统级侧边返回手势）
    if (this.showBookmarks) {
      this.showBookmarks = false;
      return true;
    }
    if (this.showSyncPanel) {
      this.showSyncPanel = false;
      return true;
    }
    if (this.showHistoryPanel) {
      this.showHistoryPanel = false;
      return true;
    }
    if (this.showDownloadPanel) {
      this.showDownloadPanel = false;
      return true;
    }
    if (this.showTabsPanel) {
      this.showTabsPanel = false;
      return true;
    }
    if (this.showMenuPanel) {
      this.showMenuPanel = false;
      return true;
    }

    // 统一走安全回退逻辑，避免直接回退到空白页
    this.goBackward();
    return true; // 阻止系统默认返回
  }

  build() {
    Column({ space: 8 }) {
      // 地址栏 - 根据滑动方向显示/隐藏（带动画）
      Column({ space: 0 }) {
        Row({ space: 8 }) {
          // 搜索图标 或 书签星标
          if (this.addressInputFocused) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(20)
              .fontColor(['#999999'])
              .margin({ left: 12 })
          } else {
            if (this.getCurrentBookmark()) {
              SymbolGlyph($r('sys.symbol.star_fill'))
                .fontSize(20)
                .fontColor(['#FFB800'])
                .margin({ left: 12 })
            } else {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(20)
                .fontColor(['#999999'])
                .margin({ left: 12 })
            }
          }

          TextInput({ text: this.addressInput, placeholder: '搜索或输入网址', controller: this.addressInputController })
            .height(44)
            .layoutWeight(1)
            .backgroundColor('#FFFFFF')
            .borderRadius(22)
            .placeholderFont({ size: 15 })
            .placeholderColor('#999999')
            .fontColor('#1A1A1A')
            .fontSize(15)
            .onChange((value: string) => {
              this.addressInput = value;
              if (this.addressInputFocused) {
                this.updateSuggestions(value);
              }
            })
            .onFocus(() => {
              this.addressInputFocused = true;
              // 聚焦时切换为URL，方便编辑
              this.addressInput = this.currentUrl;
              this.updateSuggestions(this.addressInput);
              // 延迟全选，等待文本更新后执行
              setTimeout(() => {
                this.addressInputController.setTextSelection(0, this.addressInput.length);
              }, 0);
            })
            .onBlur(() => {
              this.addressInputFocused = false;
              // 失焦时切换为书签标题（如有）
              const bm = this.getCurrentBookmark();
              if (bm) {
                this.addressInput = bm.title;
              }
              // 延迟隐藏，允许点击建议项
              setTimeout(() => {
                this.showSuggestions = false;
              }, 200);
            })
            .onSubmit(() => {
              this.showSuggestions = false;
              this.openByInput();
            })

          // 刷新按钮
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
              .fontSize(20)
              .fontColor(['#007DFF'])
          }
          .width(44)
          .height(44)
          .backgroundColor('#FFFFFF')
          .borderRadius(22)
          .shadow({
            radius: 4,
            color: 'rgba(0, 0, 0, 0.08)',
            offsetX: 0,
            offsetY: 2
          })
          .onClick(() => {
            this.refreshPage();
          })
        }
        .width('100%')
        .height(56)
        .padding({ left: 8, right: 8 })
        .backgroundColor(this.getCurrentTab()?.isPrivate ? '#F5F0FA' : '#FFFFFF')
        .shadow({
          radius: 4,
          color: 'rgba(0, 0, 0, 0.06)',
          offsetX: 0,
          offsetY: 2
        })
      }
      .height(this.addressBarVisible ? 64 : 0)
      .clip(true)
      .animation({
        duration: 300,
        curve: Curve.EaseOut
      })

      // 建议列表 - 仅在地址框获得焦点时显示
      if (this.addressInputFocused && this.showSuggestions && this.suggestions.length > 0) {
        Stack() {
          List({ space: 0 }) {
            ForEach(this.suggestions, (item: SuggestionItem) => {
              ListItem() {
                Row({ space: 12 }) {
                  // 图标
                  SymbolGlyph(item.type === 'bookmark' ? $r('sys.symbol.star_fill') : $r('sys.symbol.clock'))
                    .fontSize(18)
                    .fontColor([item.type === 'bookmark' ? '#FFB800' : '#999999'])

                  // 标题和URL
                  Column({ space: 2 }) {
                    Text(item.title || item.url)
                      .fontSize(14)
                      .fontColor('#1A1A1A')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })

                    if (item.title) {
                      Text(item.url)
                        .fontSize(12)
                        .fontColor('#999999')
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                }
                .width('100%')
                .height(56)
                .padding({ left: 16, right: 16 })
                .backgroundColor('#FFFFFF')
                .onClick(() => {
                  this.currentUrl = item.url;
                  this.addressInput = item.url;
                  this.showSuggestions = false;
                  this.webController.loadUrl(item.url);
                })
              }
            }, (item: SuggestionItem) => item.url)
          }
          .width('100%')
          .height(Math.min(this.suggestions.length * 56, 280))
          .backgroundColor('#FFFFFF')
          .borderRadius({ bottomLeft: 12, bottomRight: 12 })
          .shadow({
            radius: 8,
            color: 'rgba(0, 0, 0, 0.1)',
            offsetX: 0,
            offsetY: 4
          })

          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.link'))
              .fontSize(14)
              .fontColor(['#5F27CD'])
          }
          .width(28)
          .height(28)
          .backgroundColor('#F3EEFF')
          .borderRadius(14)
          .position({ top: 8, right: 12 })
          .onClick(() => {
            this.copyCurrentLink();
          })
        }
        .width('100%')
        .margin({ top: -8 })
      }

      // 浏览区域容器 - 包含Web组件和弹出面板
      Stack() {
        Web({ src: this.currentUrl, controller: this.webController })
        .width('100%')
        .height('100%')
        .backgroundColor(this.getCurrentTab()?.isPrivate ? '#F8F5FC' : '#FFFFFF')
        .domStorageAccess(true)
        // "电脑版/手机版" 切换（User-Agent）
        .userAgent(this.preferDesktopSite ? this.DESKTOP_USER_AGENT : this.MOBILE_USER_AGENT)
      .onDownloadStart((event: DownloadStartEvent) => {
        // 拦截下载请求，添加到下载管理
        const downloadUrl = event.url;
        if (downloadUrl && downloadUrl.startsWith('http')) {
          this.startDownload(downloadUrl);
        }
      })
      .onPageBegin(() => {
        this.isLoading = true;
        this.loadProgress = 0;
        this.statusText = '';
        this.addressBarVisible = true; // 页面加载时显示地址栏
        if (this.pendingWebErrorTimer !== null) {
          clearTimeout(this.pendingWebErrorTimer);
          this.pendingWebErrorTimer = null;
        }

        // 清除之前的定时器
        if (this.progressTimer) {
          clearInterval(this.progressTimer);
        }

        // 开始平滑增长进度
        let currentProgress = 0;
        this.progressTimer = setInterval(() => {
          if (currentProgress < 80) {
            currentProgress += 2;
            this.loadProgress = currentProgress;
          }
        }, 100);
      })
      .onPageEnd(() => {
        if (this.pendingWebErrorTimer !== null) {
          clearTimeout(this.pendingWebErrorTimer);
          this.pendingWebErrorTimer = null;
        }
        // 清除进度定时器
        if (this.progressTimer) {
          clearInterval(this.progressTimer);
          this.progressTimer = null;
        }

        // 快速到达 100%
        this.loadProgress = 100;
        this.statusText = '';

        // 同步地址栏到当前页面URL
        this.syncAddressBarFromWebView();

        // 0.5秒后消失
        setTimeout(() => {
          this.isLoading = false;
          this.loadProgress = 0;
        }, 500);
        this.recordCurrentPageToHistory();

        // 获取网页 favicon
        this.fetchFavicon();
      })
      .onErrorReceive((event: OnErrorReceiveEvent) => {
        if (!this.isLoading || this.loadProgress >= 95) {
          return;
        }
        const errorCode = event.error.getErrorCode();
        // -2/-302 常见于重定向或连接切换阶段，页面通常可正常显示；其余子资源错误也忽略
        if (this.shouldIgnoreWebError(errorCode)) {
          return;
        }
        if (this.pendingWebErrorTimer !== null) {
          clearTimeout(this.pendingWebErrorTimer);
          this.pendingWebErrorTimer = null;
        }
        // 延迟确认后再提示，避免瞬时错误覆盖正常加载结果
        this.pendingWebErrorTimer = setTimeout(() => {
          if (this.isLoading && this.loadProgress < 95) {
            this.statusText = `加载失败: ${errorCode}`;
            this.isLoading = false;
            this.loadProgress = 0;
          }
          this.pendingWebErrorTimer = null;
        }, 1200);
      })
      .onTitleReceive((data: TitleReceiveEvent) => {
        if (this.activeTabId) {
          const currentTab = this.tabs.find((tab) => tab.id === this.activeTabId);
          if (currentTab) {
            currentTab.title = data.title || '新页签';
          }
        }
      })
      .onTouch((event: TouchEvent) => {
        // 处理触摸事件，检测滑动方向
        if (event.type === TouchType.Down) {
          this.touchStartY = event.touches[0].y;
          this.touchStartX = event.touches[0].x;
        } else if (event.type === TouchType.Up) {
          const touchEndY = event.touches[0].y;
          const touchEndX = event.touches[0].x;
          const deltaY = touchEndY - this.touchStartY;
          const deltaX = touchEndX - this.touchStartX;
          const touchDistance = Math.sqrt(deltaX * deltaX + deltaY * deltaY);

          // 检测返回手势（从左向右滑动）
          if (deltaX > this.BACK_SWIPE_THRESHOLD && Math.abs(deltaY) < this.SWIPE_THRESHOLD) {
            // 关闭任何打开的面板
            if (this.showMenuPanel) {
              this.showMenuPanel = false;
              return;
            } else if (this.showBookmarks) {
              this.showBookmarks = false;
              return;
            } else if (this.showSyncPanel) {
              this.showSyncPanel = false;
              return;
            } else if (this.showHistoryPanel) {
              this.showHistoryPanel = false;
              return;
            } else if (this.showDownloadPanel) {
              this.showDownloadPanel = false;
              return;
            } else if (this.showTabsPanel) {
              this.showTabsPanel = false;
              return;
            } else {
              // 如果没有打开的面板，尝试网页返回
              this.goBackward();
            }
          }

          // 判断是否为垂直滑动（排除水平滑动且距离要足够大）
          if (Math.abs(deltaY) > this.SWIPE_THRESHOLD && Math.abs(deltaY) > Math.abs(deltaX)) {
            if (deltaY > 0) {
              // 向下滑动 - 显示地址栏（上移出现）
              this.addressBarVisible = true;
            } else {
              // 向上滑动 - 隐藏地址栏（上移消失）
              this.addressBarVisible = false;
            }
          } else if (touchDistance < 20) {
            // 点击事件 - 显示地址栏
            this.addressBarVisible = true;
          }
        }
      })

        // 加载进度条：悬浮覆盖，不占布局（避免抖动）
        Stack({ alignContent: Alignment.Top }) {
          Row()
            .width('100%')
            .height(2)
            .backgroundColor('#F0F0F0')
            .borderRadius(1)
          Row()
            .width(`${this.loadProgress}%`)
            .height(2)
            .backgroundColor('#007DFF')
            .borderRadius(1)
            .animation({
              duration: 250,
              curve: Curve.EaseOut
            })
        }
        .width('100%')
        .height(2)
        .opacity(this.isLoading ? 1 : 0)
        .position({ x: 0, y: 0 })

        // 初始空白页提示 - 现代卡片式设计
        if (!this.currentUrl) {
          Column({ space: 0 }) {
          // Logo区域
          Column({ space: 12 }) {
            Image($r('app.media.app_icon'))
              .width(64)
              .height(64)
              .borderRadius(12)

            Text('小舟浏览器')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1A1A1A')

            Text('v1.0.2')
              .fontSize(12)
              .fontColor('#999999')
              .margin({ top: 4 })
          }
          .margin({ bottom: 32 })


          // 快捷访问卡片
          Column({ space: 12 }) {
            Text('快捷访问')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#1A1A1A')
              .width('100%')


            if (this.quickAccessItems.length > 0) {
              // 显示智能快捷访问（按访问频率和收藏状态排序）
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
                ForEach(
                  this.quickAccessItems,
                  (item: SuggestionItem) => {
                    Column() {
                      Column({ space: 6 }) {
                        Image(item.type === 'bookmark' ? 
                          (this.bookmarks.find(b => b.url === item.url)?.favicon || this.getSiteIcon(item.url)) : 
                          this.getSiteIcon(item.url))
                          .width(28)
                          .height(28)
                          .borderRadius(6)
                          .alt($r('app.media.app_icon'))
                        Text(item.title.length > 6 ? item.title.substring(0, 6) + '...' : item.title)
                          .fontSize(11)
                          .fontWeight(FontWeight.Medium)
                          .fontColor('#1A1A1A')
                          .maxLines(1)
                      }
                      .width('100%')
                      .height('100%')
                      .justifyContent(FlexAlign.Center)
                    }
                    .width('calc(33.33% - 8px)')
                    .height(72)
                    .backgroundColor('#FFFFFF')
                    .borderRadius(12)
                    .shadow({
                      radius: 4,
                      color: 'rgba(0, 0, 0, 0.08)',
                      offsetX: 0,
                      offsetY: 2
                    })
                    .margin({ bottom: 12 })
                    .onClick(() => {
                      this.currentUrl = item.url;
                      this.addressInput = item.url;
                      this.openByInput();
                    })
                  }
                )
              }
              .width('100%')
            } else if (this.bookmarks.filter(b => !b.deletedFlag).length > 0) {
              // 显示最新6个书签（去重）- 备选方案
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
                ForEach(
                  this.bookmarks
                    .filter(b => !b.deletedFlag)
                    .sort((a, b) => b.updatedAt - a.updatedAt)
                    .filter((item, index, self) =>
                      self.findIndex(b => b.url === item.url) === index
                    )
                    .slice(0, 6),
                  (bookmark: Bookmark) => {
                    Column() {
                      Column({ space: 6 }) {
                        Image(bookmark.favicon || this.getSiteIcon(bookmark.url))
                          .width(28)
                          .height(28)
                          .borderRadius(6)
                          .alt($r('app.media.app_icon'))
                        Text(bookmark.title.length > 6 ? bookmark.title.substring(0, 6) + '...' : bookmark.title)
                          .fontSize(11)
                          .fontWeight(FontWeight.Medium)
                          .fontColor('#1A1A1A')
                          .maxLines(1)
                      }
                      .width('100%')
                      .height('100%')
                      .justifyContent(FlexAlign.Center)
                    }
                    .width('calc(33.33% - 8px)')
                    .height(72)
                    .backgroundColor('#FFFFFF')
                    .borderRadius(12)
                    .shadow({
                      radius: 4,
                      color: 'rgba(0, 0, 0, 0.08)',
                      offsetX: 0,
                      offsetY: 2
                    })
                    .margin({ bottom: 12 })
                    .onClick(() => {
                      this.currentUrl = bookmark.url;
                      this.addressInput = bookmark.url;
                      this.openByInput();
                    })
                  }
                )
              }
              .width('100%')
            } else {
              // 默认显示百度和 Bing
              Row({ space: 12 }) {
                Column() {
                  Column({ space: 8 }) {
                    Image(this.getSiteIcon('https://www.baidu.com'))
                      .width(40)
                      .height(40)
                      .borderRadius(8)
                      .alt($r('app.media.app_icon'))
                    Text('百度搜索')
                      .fontSize(14)
                      .fontWeight(FontWeight.Medium)
                      .fontColor('#1A1A1A')
                  }
                  .width('100%')
                  .height('100%')
                  .justifyContent(FlexAlign.Center)
                }
                .layoutWeight(1)
                .height(100)
                .backgroundColor('#FFFFFF')
                .borderRadius(16)
                .shadow({
                  radius: 8,
                  color: 'rgba(0, 0, 0, 0.08)',
                  offsetX: 0,
                  offsetY: 2
                })
                .onClick(() => {
                  this.currentUrl = 'https://www.baidu.com';
                  this.addressInput = 'https://www.baidu.com';
                  this.openByInput();
                })

                Column() {
                  Column({ space: 8 }) {
                    Image(this.getSiteIcon('https://www.bing.com'))
                      .width(40)
                      .height(40)
                      .borderRadius(8)
                      .alt($r('app.media.app_icon'))
                    Text('Bing搜索')
                      .fontSize(14)
                      .fontWeight(FontWeight.Medium)
                      .fontColor('#1A1A1A')
                  }
                  .width('100%')
                  .height('100%')
                  .justifyContent(FlexAlign.Center)
                }
                .layoutWeight(1)
                .height(100)
                .backgroundColor('#FFFFFF')
                .borderRadius(16)
                .shadow({
                  radius: 8,
                  color: 'rgba(0, 0, 0, 0.08)',
                  offsetX: 0,
                  offsetY: 2
                })
                .onClick(() => {
                  this.currentUrl = 'https://www.bing.com';
                  this.addressInput = 'https://www.bing.com';
                  this.openByInput();
                })
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding(20)
          .backgroundColor('#FFFFFF')
          .borderRadius(20)
          .shadow({
            radius: 12,
            color: 'rgba(0, 0, 0, 0.1)',
            offsetX: 0,
            offsetY: 4
          })
        }
          .width('100%')
          .height('100%')
          .backgroundColor('#F5F7FA')
          .justifyContent(FlexAlign.Center)
          .padding({ left: 24, right: 24 })
        }

        // 功能菜单面板 - 覆盖浏览区域
        if (this.showMenuPanel) {
        Stack() {
          // 半透明遮罩
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0, 0, 0, 0.3)')
            .onClick(() => {
              this.showMenuPanel = false;
            })

          // 菜单面板
          Column() {
            this.MenuPanel()
          }
            .width('100%')
            .height('100%')
            .alignItems(HorizontalAlign.Center)
        }
          .width('100%')
          .height('100%')
        }

        // 书签面板 - 覆盖浏览区域
        if (this.showBookmarks) {
        Stack() {
          // 半透明遮罩
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0, 0, 0, 0.3)')
            .onClick(() => {
              this.showBookmarks = false;
            })

          // 书签面板
          Column() {
            this.BookmarkPanel()
          }
            .width('100%')
            .height('100%')
            .alignItems(HorizontalAlign.Center)
        }
          .width('100%')
          .height('100%')
        }

        // 同步面板 - 覆盖浏览区域
        if (this.showSyncPanel) {
        Stack() {
          // 半透明遮罩
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0, 0, 0, 0.3)')
            .onClick(() => {
              this.showSyncPanel = false;
            })

          // 同步面板
          Column() {
            this.SyncPanel()
          }
            .width('100%')
            .height('100%')
            .alignItems(HorizontalAlign.Center)
        }
          .width('100%')
          .height('100%')
        }

        // 历史面板 - 覆盖浏览区域
        if (this.showHistoryPanel) {
        Stack() {
          // 半透明遮罩
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0, 0, 0, 0.3)')
            .onClick(() => {
              this.showHistoryPanel = false;
            })

          // 历史面板
          Column() {
            this.HistoryPanel()
          }
            .width('100%')
            .height('100%')
            .alignItems(HorizontalAlign.Center)
        }
          .width('100%')
          .height('100%')
        }

        // 下载管理面板 - 覆盖浏览区域
        if (this.showDownloadPanel) {
        Stack() {
          // 半透明遮罩
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0, 0, 0, 0.3)')
            .onClick(() => {
              this.showDownloadPanel = false;
            })

          // 下载管理面板
          Column() {
            this.DownloadPanel()
          }
            .width('100%')
            .height('100%')
            .alignItems(HorizontalAlign.Center)
        }
          .width('100%')
          .height('100%')
        }

        // 多页签面板 - 覆盖浏览区域
        if (this.showTabsPanel) {
          Stack() {
            // 半透明遮罩
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor('rgba(0, 0, 0, 0.3)')
              .onClick(() => {
                this.showTabsPanel = false;
              })

            // 页签面板
            Column() {
              this.TabsPanel()
            }
              .width('100%')
              .height('100%')
              .alignItems(HorizontalAlign.Center)
          }
          .width('100%')
          .height('100%')
        }
      }
      .layoutWeight(1)
      .width('100%')

      if (this.showUndoClose) {
        Row({ space: 12 }) {
          Text('✓ 页签已关闭')
            .fontSize(14)
            .fontColor('#FFFFFF')
            .layoutWeight(1)

          Button({ type: ButtonType.Normal }) {
            Text('撤销')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
          }
          .height(32)
          .backgroundColor('rgba(255, 255, 255, 0.2)')
          .borderRadius(16)
          .onClick(() => {
            this.undoCloseTab();
          })

          Button({ type: ButtonType.Normal }) {
            Text('✕')
              .fontSize(14)
              .fontColor('#FFFFFF')
          }
          .width(32)
          .height(32)
          .backgroundColor('rgba(255, 255, 255, 0.1)')
          .borderRadius(16)
          .onClick(() => {
            this.showUndoClose = false;
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .backgroundColor('#007DFF')
        .borderRadius(12)
        .margin({ left: 12, right: 12 })
        .shadow({
          radius: 8,
          color: 'rgba(0, 125, 255, 0.3)',
          offsetX: 0,
          offsetY: 2
        })
      }

      this.BottomBar()

      // 快捷笔记浮窗
      if (this.showQuickNote) {
        this.QuickNotePanel()
      }

      // 阅读模式面板
      if (this.showReadingMode) {
        this.ReadingModePanel()
      }
    }
    .height('100%')
    .width('100%')
    .padding(12)
    .onAppear(() => {
      this.initBookmarkRepository();
      this.initHistoryRepository();
      this.initWebDavConfigRepository();
      this.initSyncLogRepository();
      this.loadBookmarks();
      this.loadSyncLogs();
      this.loadWebDavConfig();

      // 初始化页签
      this.initTabs();

      // 加载历史后显示上次访问的页面
      this.loadHistoryRecordsAndRestorePage();
    })
  }

  // 初始化页签
  private initTabs(): void {
    if (this.tabs.length === 0) {
      this.createNewTab();
    }
  }

  private loadHistoryRecordsAndRestorePage(): void {
    if (this.historyRepository === null) {
      this.historyRecords = [];
      return;
    }
    this.historyRepository.listRecords()
      .then((items: HistoryRecord[]) => {
        this.historyRecords = items;
        // 计算智能快捷访问
        this.calculateQuickAccess();
        // 启动时保持主页空白，不自动恢复历史页面
      })
      .catch(() => {
        this.statusText = '读取历史失败';
      });
  }

  @Builder
  private MenuPanel() {
    Column({ space: 16 }) {
      // 标题栏
      Text('功能菜单')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1A1A1A')
        .width('100%')
        .textAlign(TextAlign.Center)

      // 菜单项网格
      Grid() {
        GridItem() {
          this.MenuItem($r('sys.symbol.plus'), '添加书签', '#2F7DFD', () => {
            if (this.currentUrl) {
              this.saveBookmark();
            } else {
              this.showToast('当前无页面可收藏');
            }
            this.showMenuPanel = false;
          })
        }

        GridItem() {
          this.MenuItem($r('sys.symbol.ohos_star'), '书签', '#007DFF', () => {
            this.showBookmarks = !this.showBookmarks;
            this.showHistoryPanel = false;
            this.showSyncPanel = false;
            this.showMenuPanel = false;
            if (this.showBookmarks) {
              this.loadBookmarks();
            }
          })
        }

        GridItem() {
          this.MenuItem($r('sys.symbol.clock'), '历史', '#00AA88', () => {
            this.showHistoryPanel = !this.showHistoryPanel;
            this.showBookmarks = false;
            this.showSyncPanel = false;
            this.showMenuPanel = false;
            if (this.showHistoryPanel) {
              this.loadHistoryRecords();
            }
          })
        }

        GridItem() {
          this.MenuItem($r('sys.symbol.arrow_counterclockwise'), '同步', '#FF6B35', () => {
            this.showSyncPanel = !this.showSyncPanel;
            this.showBookmarks = false;
            this.showHistoryPanel = false;
            this.showMenuPanel = false;
            if (this.showSyncPanel) {
              this.syncDraftTouched = false;
              this.loadWebDavConfig();
            }
          })
        }

        GridItem() {
          this.MenuItem($r('sys.symbol.ohos_trash'), '清空历史', '#FF4757', () => {
            this.clearHistoryRecords();
            this.showMenuPanel = false;
          })
        }

        GridItem() {
          this.MenuItem($r('sys.symbol.arrow_down'), '下载管理', '#00AAFF', () => {
            this.showDownloadPanel = true;
            this.showBookmarks = false;
            this.showHistoryPanel = false;
            this.showSyncPanel = false;
            this.showMenuPanel = false;
          })
        }

        GridItem() {
          this.MenuItem($r('sys.symbol.doc_text'), '笔记', '#007DFF', () => {
            if (this.navigatingToNotes) {
              return;
            }
            this.navigatingToNotes = true;
            this.openNoteListPage();
          })
        }

        GridItem() {
          this.MenuItem($r('sys.symbol.square_grid_2x2'), this.preferDesktopSite ? '电脑版' : '手机版', '#5F27CD', () => {
            this.preferDesktopSite = !this.preferDesktopSite;
            this.showMenuPanel = false;
            this.showToast(this.preferDesktopSite ? '已切换：电脑版' : '已切换：手机版');
            try {
              // Refresh current page to apply UA immediately
              this.webController.refresh();
            } catch (_) {
            }
          })
        }

      }
      .columnsTemplate('1fr 1fr')
      .columnsGap(16)
      .rowsGap(16)
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .backgroundColor('#FFFFFF')
  }

  @Builder
  private MenuItem(iconResource: Resource, text: string, color: string, onClick: () => void) {
    Column({ space: 6 }) {
      Column() {
        SymbolGlyph(iconResource)
          .fontSize(24)
          .fontColor([color])
      }
      .width(52)
      .height(52)
      .backgroundColor('#FFFFFF')
      .borderRadius(12)
      .justifyContent(FlexAlign.Center)
      .shadow({
        radius: 3,
        color: 'rgba(0, 0, 0, 0.12)',
        offsetX: 0,
        offsetY: 2
      })

      Text(text)
        .fontSize(12)
        .fontColor('#666666')
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding(4)
    .onClick(onClick)
  }

  @Builder
  private DownloadPanel() {
    Column({ space: 12 }) {
      // 标题栏
      Row({ space: 8 }) {
        Text('下载管理')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1A1A1A')
          .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(20)
          .fontColor(['#999999'])
          .onClick(() => {
            this.showDownloadPanel = false;
          })
      }
      .width('100%')

      // 下载记录列表
      if (this.downloadRecords.length === 0) {
        Column({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.arrow_down'))
            .fontSize(48)
            .fontColor(['#CCCCCC'])
          Text('暂无下载记录')
            .fontSize(14)
            .fontColor('#999999')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.downloadRecords, (record: DownloadRecord) => {
            ListItem() {
              Row({ space: 12 }) {
                Column({ space: 4 }) {
                  Text(record.fileName || this.getFileNameFromUrl(record.url))
                    .fontSize(14)
                    .fontColor('#1A1A1A')
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(record.url)
                    .fontSize(11)
                    .fontColor('#999999')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Row({ space: 8 }) {
                  if (record.status === 'completed') {
                    Button('打开')
                      .fontSize(12)
                      .height(28)
                      .padding({ left: 12, right: 12 })
                      .fontColor('#FFFFFF')
                      .backgroundColor('#2F7DFD')
                      .borderRadius(6)
                      .onClick(() => {
                        this.openDownloadedFile(record);
                      })
                  } else if (record.status === 'downloading') {
                    SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                      .fontSize(20)
                      .fontColor(['#007DFF'])
                  } else if (record.status === 'failed') {
                    Button('重试')
                      .fontSize(12)
                      .height(28)
                      .padding({ left: 12, right: 12 })
                      .fontColor('#FF4444')
                      .backgroundColor('#FFF0F0')
                      .borderRadius(6)
                      .onClick(() => {
                        this.startDownload(record.url);
                      })
                  } else {
                    SymbolGlyph($r('sys.symbol.clock'))
                      .fontSize(20)
                      .fontColor(['#999999'])
                  }

                  Button('删除')
                    .fontSize(12)
                    .height(28)
                    .padding({ left: 12, right: 12 })
                    .fontColor('#FF4444')
                    .backgroundColor('#FFF0F0')
                    .borderRadius(6)
                    .onClick(async () => {
                      const index = this.downloadRecords.findIndex(r => r.id === record.id);
                      if (index >= 0) {
                        this.downloadRecords.splice(index, 1);
                        this.downloadRecords = [...this.downloadRecords];
                        if (this.downloadRecordRepository) {
                          await this.downloadRecordRepository.deleteRecord(record.id);
                        } else {
                          this.saveDownloadRecords();
                        }
                      }
                    })
                }
              }
              .width('100%')
              .padding(12)
              .backgroundColor('#FFFFFF')
              .borderRadius(8)
            }
          }, (record: DownloadRecord) => record.id)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .backgroundColor('#FFFFFF')
  }
  private getFileNameFromUrl(urlStr: string): string {
    try {
      const parts = urlStr.split('/');
      const lastPart = parts[parts.length - 1];
      const fileName = lastPart.split('?')[0];
      return fileName.length > 0 ? fileName : '下载文件';
    } catch {
      return '下载文件';
    }
  }

  // 启动下载（弹出保存对话框让用户选择目录）
  private async startDownload(downloadUrl: string): Promise<void> {
    const fileName = this.getFileNameFromUrl(downloadUrl);
    const record: DownloadRecord = {
      id: `${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
      url: downloadUrl,
      fileName: fileName,
      filePath: '',
      totalBytes: 0,
      downloadedBytes: 0,
      status: 'pending',
      createdAt: Date.now()
    };
    this.downloadRecords = [record, ...this.downloadRecords];
    this.saveDownloadRecords();

    try {
      // 使用 DocumentViewPicker 让用户选择保存位置
      const documentSaveOptions = new picker.DocumentSaveOptions();
      documentSaveOptions.newFileNames = [fileName];
      documentSaveOptions.fileSuffixChoices = ['*'];
      const documentViewPicker = new picker.DocumentViewPicker();

      const uriResult = await documentViewPicker.save(documentSaveOptions);
      if (uriResult && uriResult.length > 0) {
        const saveUri = uriResult[0];
        // 更新记录的文件路径
        const idx = this.downloadRecords.findIndex(r => r.id === record.id);
        if (idx >= 0) {
          this.downloadRecords[idx].filePath = saveUri;
          this.downloadRecords[idx].status = 'downloading';
          this.downloadRecords = [...this.downloadRecords];
          this.saveDownloadRecords();
        }

        // 先下载到临时目录，再复制到用户选择的位置
        const context = getContext(this) as common.Context;
        const tempPath = `${context.tempDir}/${fileName}`;
        const downloadTask = request.downloadFile(context, { url: downloadUrl, filePath: tempPath });

        downloadTask.then(async (task: request.DownloadTask) => {
          task.on('progress', (receivedSize: number, totalSize: number) => {
            const i = this.downloadRecords.findIndex(r => r.id === record.id);
            if (i >= 0) {
              this.downloadRecords[i].downloadedBytes = receivedSize;
              this.downloadRecords[i].totalBytes = totalSize;
            }
          });

          task.on('complete', () => {
            // 下载完成，复制到用户选择的位置
            try {
              const srcFile = fs.openSync(tempPath, fs.OpenMode.READ_ONLY);
              const destFile = fs.openSync(saveUri, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
              const bufSize = 4096;
              let readLen = -1;
              while (readLen !== 0) {
                const buf = new ArrayBuffer(bufSize);
                readLen = fs.readSync(srcFile.fd, buf);
                if (readLen > 0) {
                  fs.writeSync(destFile.fd, buf, { length: readLen });
                }
              }
              fs.closeSync(srcFile);
              fs.closeSync(destFile);
              // 删除临时文件
              try { fs.unlinkSync(tempPath); } catch (_) {}
            } catch (e) {
              // 复制失败，但临时文件仍然可用
            }

            const i = this.downloadRecords.findIndex(r => r.id === record.id);
            if (i >= 0) {
              this.downloadRecords[i].status = 'completed';
              this.downloadRecords[i].completedAt = Date.now();
              this.downloadRecords = [...this.downloadRecords];
              this.saveDownloadRecords();
            }
            this.showToast('下载完成：' + fileName);
          });

          task.on('fail', (err: number) => {
            const i = this.downloadRecords.findIndex(r => r.id === record.id);
            if (i >= 0) {
              this.downloadRecords[i].status = 'failed';
              this.downloadRecords = [...this.downloadRecords];
              this.saveDownloadRecords();
            }
            this.showToast('下载失败：' + fileName);
          });
        }).catch(() => {
          this.updateDownloadRecord(record.id, 'failed');
          this.showToast('下载失败：' + fileName);
        });
      } else {
        // 用户取消选择
        const idx = this.downloadRecords.findIndex(r => r.id === record.id);
        if (idx >= 0) {
          this.downloadRecords.splice(idx, 1);
          this.downloadRecords = [...this.downloadRecords];
          this.saveDownloadRecords();
        }
      }
    } catch (e) {
      this.updateDownloadRecord(record.id, 'failed');
      this.showToast('下载失败：' + fileName);
    }
  }

  // 添加下载记录（手动触发用）
  private addDownloadRecord(url: string): void {
    this.startDownload(url);
  }

  // 打开已下载的文件
  private openDownloadedFile(record: DownloadRecord): void {
    if (!record.filePath || record.filePath.length === 0) {
      this.showToast('文件路径不存在');
      return;
    }
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: record.filePath,
        type: this.getMimeTypeFromFileName(record.fileName)
      };
      context.startAbility(want)
        .catch(() => {
          this.showToast('无法打开此文件类型');
        });
    } catch (e) {
      this.showToast('打开文件失败');
    }
  }

  // 根据文件名获取MIME类型
  private getMimeTypeFromFileName(fileName: string): string {
    const ext = fileName.split('.').pop()?.toLowerCase() || '';
    const mimeMap: Record<string, string> = {
      'pdf': 'application/pdf',
      'doc': 'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'mp3': 'audio/mpeg',
      'mp4': 'video/mp4',
      'txt': 'text/plain',
      'html': 'text/html',
      'zip': 'application/zip',
      'apk': 'application/vnd.android.package-archive'
    };
    return mimeMap[ext] || '*/*';
  }

  // 更新下载记录状态
  private updateDownloadRecord(id: string, status: 'pending' | 'downloading' | 'completed' | 'failed'): void {
    const index = this.downloadRecords.findIndex(r => r.id === id);
    if (index >= 0) {
      this.downloadRecords[index].status = status;
      if (status === 'completed') {
        this.downloadRecords[index].completedAt = Date.now();
      }
      this.downloadRecords = [...this.downloadRecords];
      this.saveDownloadRecords();
    }
  }

  @Builder
  private TabsPanel() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(`页签 (${this.tabs.length})`)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)

        if (this.closedTabs.length > 0) {
          Button('恢复')
            .fontSize(12)
            .fontColor('#2F7DFD')
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.undoCloseTab();
              this.showTabsPanel = false;
            })
        }


      }
      .width('100%')
      .padding({ bottom: 8 })

      if (this.tabs.length === 0) {
        Column({ space: 12 }) {
          Text('暂无页签')
            .fontSize(14)
            .fontColor('#999999')
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding(20)

          Button('+')
            .width('100%')
            .height(44)
            .fontSize(24)
            .fontColor('#FFFFFF')
            .backgroundColor('#2F7DFD')
            .borderRadius(8)
            .onClick(() => {
              this.createNewTab();
              this.showTabsPanel = false;
            })

          Text('v1.0.2')
            .fontSize(12)
            .fontColor('#CCCCCC')
            .margin({ top: 8 })
        }
      } else {
        Grid() {
          ForEach(this.tabs, (tab: Tab) => {
            GridItem() {
              Column({ space: 6 }) {
                Stack({ alignContent: Alignment.Top }) {
                  Column() {
                    if (tab.isSleeping) {
                      Text('💤')
                        .fontSize(32)
                        .width(80)
                        .height(60)
                        .backgroundColor('#E8E8E8')
                        .borderRadius(4)
                        .textAlign(TextAlign.Center)
                    } else if (tab.thumbnail) {
                      Image(tab.thumbnail)
                        .width(80)
                        .height(60)
                        .objectFit(ImageFit.Cover)
                        .borderRadius(4)
                    } else {
                      Image(tab.favicon || this.getSiteIcon(tab.url))
                        .width(32)
                        .height(32)
                        .borderRadius(6)
                        .alt($r('app.media.app_icon'))
                        .backgroundColor(tab.isPrivate ? '#2D1B4E' : '#E8F0FF')
                    }
                  }
                  .width(80)
                  .height(60)
                  .border(tab.isPrivate ? { width: 2, color: '#6B4C9A' } : { width: 0 })
                  .justifyContent(FlexAlign.Center)

                  Row({ space: 4 }) {
                    Button({ type: ButtonType.Circle }) {
                      SymbolGlyph($r('sys.symbol.pin'))
                        .fontSize(10)
                        .fontColor([tab.isPinned ? '#FF6600' : '#CCCCCC'])
                    }
                    .width(16)
                    .height(16)
                    .backgroundColor(Color.Transparent)
                    .onClick(() => {
                      this.togglePinTab(tab.id);
                    })

                    Button({ type: ButtonType.Circle }) {
                      SymbolGlyph($r('sys.symbol.xmark'))
                        .fontSize(8)
                        .fontColor(['#FFFFFF'])
                    }
                    .width(16)
                    .height(16)
                    .backgroundColor('#666666')
                    .onClick(() => {
                      this.closeTab(tab.id);
                    })
                  }
                  .width(80)
                  .justifyContent(FlexAlign.SpaceBetween)
                  .position({ y: 0 })

                  if (tab.isPrivate) {
                    SymbolGlyph($r('sys.symbol.lock'))
                      .fontSize(10)
                      .fontColor(['#666666'])
                      .position({ x: 65, y: 45 })
                  }
                }
                .width(80)
                .height(60)

                Text(tab.title.length > 8 ? tab.title.substring(0, 8) + '...' : (tab.title || '新页签'))
                  .fontSize(12)
                  .fontColor('#333333')
                  .maxLines(1)
                  .textAlign(TextAlign.Center)
                  .width(80)
              }
              .width('100%')
              .padding(8)
              .backgroundColor(tab.isPrivate ? (tab.id === this.activeTabId ? '#E8E0F0' : '#F5F0FA') : (tab.id === this.activeTabId ? '#E8F0FF' : '#FFFFFF'))
              .borderRadius(8)
              .border(tab.id === this.activeTabId ? { width: 2, color: tab.isPrivate ? '#6B4C9A' : '#2F7DFD' } : (tab.isPrivate ? { width: 1, color: '#6B4C9A' } : {}))
              .onClick(() => {
                this.switchToTab(tab.id);
              })
            }
          }, (tab: Tab) => tab.id)
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(8)
        .rowsGap(8)
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
      }

      Row({ space: 8 }) {
        Button('+ 新建')
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor('#2F7DFD')
          .borderRadius(8)
          .onClick(() => {
            this.createNewTab();
            this.showTabsPanel = false;
          })

        Button('🔒 隐私')
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor('#6B4C9A')
          .backgroundColor('#F5F0FA')
          .border({ width: 2, color: '#6B4C9A' })
          .borderRadius(8)
          .onClick(() => {
            this.createPrivateTab();
            this.showTabsPanel = false;
          })

        if (this.tabs.length > 1) {
          Button('全部关闭')
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .fontColor('#FF4444')
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: '#FF4444' })
            .borderRadius(8)
            .onClick(() => {
              this.closeAllTabs();
            })
        }
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor('#F7F8FA')
  }

  private getSiteIcon(url: string): string {
    if (!url) {
      return '';
    }
    try {
      // 获取网站域名
      const domain = url.toLowerCase().replace(/^https?:\/\//, '').split('/')[0];
      // 返回网站根目录的 favicon.ico（最通用的方式）
      return `https://${domain}/favicon.ico`;
    } catch (_) {
      return '';
    }
  }

  private closeAllTabs(): void {
    const pinnedTabs = this.tabs.filter((tab) => tab.isPinned);
    const activeTab = this.tabs.find((tab) => tab.id === this.activeTabId);

    for (const tab of this.tabs) {
      if (!tab.isPinned && !tab.isPrivate) {
        const index = this.closedTabs.findIndex((t) => t.id === tab.id);
        if (index === -1 && this.closedTabs.length < this.MAX_CLOSED_TABS) {
          this.closedTabs.unshift(tab);
        }
      }
    }

    this.tabs = pinnedTabs;

    if (this.tabs.length === 0) {
      this.createNewTab();
    } else if (!activeTab || !this.tabs.find((t) => t.id === activeTab.id)) {
      this.switchToTab(this.tabs[0].id);
    }

    this.showTabsPanel = false;
    this.showUndoClose = true;
    setTimeout(() => {
      this.showUndoClose = false;
    }, 10000);
  }

  @Builder
  private BottomBar() {
    Row({ space: 6 }) {
      // 后退按钮
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(22)
          .fontColor(['#1A1A1A'])
      }
      .layoutWeight(1)
      .height(40)
      .backgroundColor('#FFFFFF')
      .borderRadius(0)
      .shadow({
        radius: 2,
        color: 'rgba(0, 0, 0, 0.08)',
        offsetX: 0,
        offsetY: 1
      })
      .onClick(() => {
        this.showMenuPanel = false;
        this.showTabsPanel = false;
        this.goBackward();
      })

      // 前进按钮
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(22)
          .fontColor(['#1A1A1A'])
      }
      .layoutWeight(1)
      .height(40)
      .backgroundColor('#FFFFFF')
      .borderRadius(0)
      .shadow({
        radius: 2,
        color: 'rgba(0, 0, 0, 0.08)',
        offsetX: 0,
        offsetY: 1
      })
      .onClick(() => {
        this.showMenuPanel = false;
        this.showTabsPanel = false;
        this.goForward();
      })

      // 主页按钮（置空浏览器）
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.house'))
          .fontSize(20)
          .fontColor(['#1A1A1A'])
      }
      .layoutWeight(1)
      .height(40)
      .backgroundColor('#FFFFFF')
      .borderRadius(0)
      .shadow({
        radius: 2,
        color: 'rgba(0, 0, 0, 0.08)',
        offsetX: 0,
        offsetY: 1
      })
      .onClick(() => {
        this.showMenuPanel = false;
        this.showTabsPanel = false;
        // 主页功能：置空浏览器
        this.currentUrl = '';
        this.addressInput = '';
        this.isLoading = false;
        this.loadProgress = 0;
        this.statusText = '';
        // 清空当前页签的URL
        if (this.activeTabId) {
          const currentTab = this.tabs.find((tab) => tab.id === this.activeTabId);
          if (currentTab) {
            currentTab.url = '';
            currentTab.title = '新页签';
          }
        }
      })

      // 页签按钮
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.ellipsis_circle'))
          .fontSize(20)
          .fontColor(['#1A1A1A'])
      }
      .layoutWeight(1)
      .height(40)
      .backgroundColor(this.tabs.length > 1 ? '#E8F4FF' : '#FFFFFF')
      .borderRadius(0)
      .shadow({
        radius: 2,
        color: 'rgba(0, 0, 0, 0.08)',
        offsetX: 0,
        offsetY: 1
      })
      .onClick(() => {
        this.showTabsPanel = !this.showTabsPanel;
        this.showMenuPanel = false;
        this.showBookmarks = false;
        this.showHistoryPanel = false;
        this.showSyncPanel = false;
      })

      // 菜单按钮
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.square_grid_2x2'))
          .fontSize(18)
          .fontColor(['#1A1A1A'])
      }
      .layoutWeight(1)
      .height(40)
      .backgroundColor('#FFFFFF')
      .borderRadius(0)
      .shadow({
        radius: 2,
        color: 'rgba(0, 0, 0, 0.08)',
        offsetX: 0,
        offsetY: 1
      })
      .onClick(() => {
        this.showMenuPanel = !this.showMenuPanel;
        this.showTabsPanel = false;
        this.showBookmarks = false;
        this.showHistoryPanel = false;
        this.showSyncPanel = false;
      })
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
    .backgroundColor('#F5F7FA')
  }

  private openByInput(): void {
    const input = this.addressInput.trim();
    if (input.length === 0) {
      this.statusText = '请输入网址或搜索词';
      return;
    }

    const target = this.toNavigableUrl(input);
    this.currentUrl = target;
    this.addressInput = target;
    this.loadProgress = 15;

    // 关闭所有面板
    this.showMenuPanel = false;
    this.showBookmarks = false;
    this.showHistoryPanel = false;
    this.showSyncPanel = false;
    this.showDownloadPanel = false;
    this.showTabsPanel = false;

    // 更新当前页签的URL
    this.updateCurrentTab(target);

    try {
      this.webController.loadUrl(target);
    } catch (_) {
      this.isLoading = false;
      this.loadProgress = 0;
      this.statusText = '页面加载失败，请检查网络或地址';
    }
  }

  // 更新建议列表
  private async updateSuggestions(keyword: string): Promise<void> {
    const trimmedKeyword = keyword.trim().toLowerCase();

    // 如果输入为空，不显示建议
    if (trimmedKeyword.length === 0) {
      this.showSuggestions = false;
      this.suggestions = [];
      return;
    }

    const matchedSuggestions: SuggestionItem[] = [];

    // 从收藏夹中匹配
    if (this.bookmarkRepository) {
      try {
        const bookmarks = await this.bookmarkRepository.listBookmarks(false);
        const matchedBookmarks = bookmarks
          .filter((b: Bookmark) =>
            !b.deletedFlag &&
            (b.title.toLowerCase().includes(trimmedKeyword) ||
             b.url.toLowerCase().includes(trimmedKeyword))
          )
          .slice(0, 5)  // 最多5个收藏夹建议
          .map((b: Bookmark) => {
            const suggestion: SuggestionItem = {
              title: b.title,
              url: b.url,
              type: 'bookmark'
            };
            return suggestion;
          });
        matchedSuggestions.push(...matchedBookmarks);
      } catch (e) {
        console.error('Failed to load bookmark suggestions:', e);
      }
    }

    // 从历史记录中匹配
    if (this.historyRepository) {
      try {
        const records = await this.historyRepository.listRecords();
        const matchedHistory = records
          .filter((r: HistoryRecord) =>
            r.title.toLowerCase().includes(trimmedKeyword) ||
            r.url.toLowerCase().includes(trimmedKeyword)
          )
          .slice(0, 5)  // 最多5个历史记录建议
          .map((r: HistoryRecord) => {
            const suggestion: SuggestionItem = {
              title: r.title,
              url: r.url,
              type: 'history'
            };
            return suggestion;
          });
        matchedSuggestions.push(...matchedHistory);
      } catch (e) {
        console.error('Failed to load history suggestions:', e);
      }
    }

    // 去重（相同URL只保留一个，优先收藏夹）
    const seenUrls = new Set<string>();
    const uniqueSuggestions: SuggestionItem[] = [];
    for (const item of matchedSuggestions) {
      if (!seenUrls.has(item.url)) {
        seenUrls.add(item.url);
        uniqueSuggestions.push(item);
      }
    }

    this.suggestions = uniqueSuggestions.slice(0, 8);  // 总共最多8个建议
    this.showSuggestions = this.suggestions.length > 0;
  }

  private copyCurrentLink(): void {
    const target = this.currentUrl.trim().length > 0 ? this.currentUrl : this.addressInput.trim();
    if (target.length === 0) {
      promptAction.showToast({ message: '当前没有可复制链接' });
      return;
    }
    try {
      const systemPasteboard = pasteboard.getSystemPasteboard();
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, target);
      systemPasteboard.setData(data).then(() => {
        promptAction.showToast({ message: '链接已复制' });
      }).catch(() => {
        promptAction.showToast({ message: '复制失败' });
      });
    } catch (_) {
      promptAction.showToast({ message: '复制失败' });
    }
  }

  // 计算智能快捷访问列表
  private calculateQuickAccess(): void {
    const TEN_DAYS_MS = 10 * 24 * 60 * 60 * 1000;
    const now = Date.now();
    const tenDaysAgo = now - TEN_DAYS_MS;

    // 统计最近10天历史记录的访问次数（按origin分组）
    const originAccessCount = new Map<string, number>();
    const originTitleMap = new Map<string, string>();

    for (const record of this.historyRecords) {
      if (record.visitedAt >= tenDaysAgo && record.url.startsWith('http')) {
        const origin = this.getUrlOrigin(record.url);
        if (origin.length === 0) {
          continue;
        }

        const count = originAccessCount.get(origin) || 0;
        originAccessCount.set(origin, count + 1);

        if (!originTitleMap.has(origin)) {
          originTitleMap.set(origin, record.title || origin);
        }
      }
    }

    // origin -> bookmark（同 origin 多个书签时保留最近更新的）
    const bookmarkByOrigin = new Map<string, Bookmark>();
    for (const bookmark of this.bookmarks) {
      if (bookmark.deletedFlag || !bookmark.url.startsWith('http')) {
        continue;
      }
      const origin = this.getUrlOrigin(bookmark.url);
      if (origin.length === 0) {
        continue;
      }
      const existing = bookmarkByOrigin.get(origin);
      if (!existing || bookmark.updatedAt > existing.updatedAt) {
        bookmarkByOrigin.set(origin, bookmark);
      }
    }

    // 按访问次数排序的origin列表
    const sortedOrigins = Array.from(originAccessCount.entries())
      .sort((a, b) => b[1] - a[1])
      .map(entry => entry[0]);

    // 规则：
    // 1) 先从书签中取最近10天访问最多的网站
    // 2) 不足6个再用历史高频补充
    const result: SuggestionItem[] = [];
    const usedOrigins = new Set<string>();

    // 第一步：书签优先
    for (const origin of sortedOrigins) {
      if (result.length >= 6) {
        break;
      }
      const bookmark = bookmarkByOrigin.get(origin);
      if (bookmark && !usedOrigins.has(origin)) {
        result.push({
          title: bookmark.title,
          url: bookmark.url,
          type: 'bookmark'
        });
        usedOrigins.add(origin);
      }
    }

    // 第二步：历史补充
    if (result.length < 6) {
      for (const origin of sortedOrigins) {
        if (result.length >= 6) {
          break;
        }
        if (!usedOrigins.has(origin)) {
          result.push({
            title: originTitleMap.get(origin) || origin,
            url: origin,
            type: 'history'
          });
          usedOrigins.add(origin);
        }
      }
    }

    this.quickAccessItems = result.slice(0, 6);
  }

  // 创建新页签
  private createNewTab(isPrivate: boolean = false): void {
    const newTab: Tab = {
      id: `${Date.now()}_${Math.floor(Math.random() * 1000)}`,
      title: '新页签',
      url: '',
      favicon: '',
      thumbnail: '',
      isPinned: false,
      isPrivate: isPrivate,
      isSleeping: false,
      lastAccessTime: Date.now()
    };
    this.tabs.push(newTab);
    this.switchToTab(newTab.id);
  }

  // 获取当前活动页签
  private getCurrentTab(): Tab | undefined {
    if (!this.activeTabId) {
      return undefined;
    }
    return this.tabs.find((tab) => tab.id === this.activeTabId);
  }

  // 创建隐私页签
  private createPrivateTab(): void {
    this.createNewTab(true);
  }

  // 切换到指定页签
  private switchToTab(tabId: string): void {
    if (this.activeTabId === tabId) {
      this.showTabsPanel = false;
      return;
    }

    if (this.activeTabId) {
      const currentTab = this.tabs.find((tab) => tab.id === this.activeTabId);
      if (currentTab && this.currentUrl) {
        currentTab.url = this.currentUrl;
        currentTab.lastAccessTime = Date.now();
      }
    }

    this.activeTabId = tabId;

    const targetTab = this.tabs.find((tab) => tab.id === tabId);
    if (targetTab) {
      this.currentUrl = targetTab.url;
      this.addressInput = targetTab.url;
      targetTab.lastAccessTime = Date.now();

      if (targetTab.isSleeping) {
        targetTab.isSleeping = false;
      }

      if (targetTab.url) {
        try {
          this.webController.loadUrl(targetTab.url);
        } catch (_) {
        }
      } else {
        try {
          this.webController.loadUrl('about:blank');
        } catch (_) {
        }
      }
    }

    this.showTabsPanel = false;
    this.resetSleepTimer();
  }

  // 关闭指定页签
  private closeTab(tabId: string): void {
    const index = this.tabs.findIndex((tab) => tab.id === tabId);
    if (index === -1) {
      return;
    }

    const wasActive = this.activeTabId === tabId;
    const closedTab = this.tabs[index];

    if (!closedTab.isPrivate && this.closedTabs.length < this.MAX_CLOSED_TABS) {
      this.closedTabs.unshift(closedTab);
    }

    this.tabs.splice(index, 1);

    if (wasActive) {
      if (this.tabs.length > 0) {
        const newIndex = Math.min(index, this.tabs.length - 1);
        const nextTab = this.tabs[newIndex];
        if (nextTab) {
          this.activeTabId = nextTab.id;
          this.currentUrl = nextTab.url;
          this.addressInput = nextTab.url;
          if (nextTab.url) {
            try {
              this.webController.loadUrl(nextTab.url);
            } catch (_) {
            }
          }
        }
      } else {
        this.activeTabId = '';
        this.currentUrl = '';
        this.addressInput = '';
        this.createNewTab();
      }
    }

    if (this.tabs.length <= 1) {
      this.showTabsPanel = false;
    }

    this.showUndoClose = true;
    setTimeout(() => {
      this.showUndoClose = false;
    }, 10000);
  }

  // 撤销关闭页签
  private undoCloseTab(): void {
    if (this.closedTabs.length === 0) {
      return;
    }
    const lastClosed = this.closedTabs.shift();
    if (lastClosed) {
      lastClosed.lastAccessTime = Date.now();
      this.tabs.push(lastClosed);
      this.switchToTab(lastClosed.id);
    }
    this.showUndoClose = false;
  }

  // 置顶/取消置顶页签
  private togglePinTab(tabId: string): void {
    const tab = this.tabs.find((t) => t.id === tabId);
    if (tab) {
      tab.isPinned = !tab.isPinned;
    }
  }

  // 手动休眠页签
  private sleepTab(tabId: string): void {
    const tab = this.tabs.find((t) => t.id === tabId);
    if (tab) {
      tab.isSleeping = true;
    }
  }

  // 重置休眠定时器
  private resetSleepTimer(): void {
    if (this.sleepTimer !== null) {
      clearTimeout(this.sleepTimer);
    }
    this.sleepTimer = setTimeout(() => {
      this.checkTabsSleep();
    }, this.SLEEP_THRESHOLD);
  }

  // 检查并休眠不活跃的页签
  private checkTabsSleep(): void {
    const now = Date.now();
    for (const tab of this.tabs) {
      if (tab.id !== this.activeTabId && !tab.isPinned && !tab.isSleeping) {
        if (now - tab.lastAccessTime > this.SLEEP_THRESHOLD) {
          tab.isSleeping = true;
        }
      }
    }
  }

  // 清理闲置超时的页签
  private cleanIdleTabs(): void {
    const now = Date.now();
    for (let i = this.tabs.length - 1; i >= 0; i--) {
      const tab = this.tabs[i];
      if (!tab.isPinned && now - tab.lastAccessTime > this.AUTO_CLOSE_THRESHOLD) {
        this.tabs.splice(i, 1);
      }
    }
  }

  // 保存当前页签状态
  private saveCurrentTabState(): void {
    if (!this.activeTabId) {
      return;
    }

    const currentTab = this.tabs.find((tab) => tab.id === this.activeTabId);
    if (currentTab) {
      currentTab.url = this.currentUrl;
      currentTab.title = this.currentUrl || '新页签';
    }
  }

  // 更新当前页签URL
  private updateCurrentTab(url: string): void {
    if (!this.activeTabId) {
      return;
    }

    const currentTab = this.tabs.find((tab) => tab.id === this.activeTabId);
    if (currentTab) {
      currentTab.url = url;
    }
  }

  private canGoBackward(): boolean {
    try {
      return this.webController.accessBackward();
    } catch (_) {
      return false;
    }
  }

  private canGoForward(): boolean {
    try {
      return this.webController.accessForward();
    } catch (_) {
      return false;
    }
  }

  private goBackward(): void {
    const actionId = ++this.navToastActionId;
    this.navToastShownForActionId = 0;
    try {
      if (!this.canGoBackward()) {
        this.returnToHomeFromBack(actionId);
        return;
      }
      this.webController.backward();
      this.showNavToastOnce(actionId, '已后退');
      // 回退后做多次兜底检测：若落到首项/空白，则统一回主页。
      const checkAfterBack = () => {
        try {
          const urlText = this.webController.getUrl();
          const noMoreBack = !this.canGoBackward();
          if (urlText.length === 0 || urlText === 'about:blank' || noMoreBack) {
            this.returnToHomeFromBack(actionId);
          }
        } catch (_) {
        }
      };
      setTimeout(checkAfterBack, 120);
      setTimeout(checkAfterBack, 280);
      setTimeout(checkAfterBack, 600);
    } catch (_) {
      this.statusText = '无法后退';
    }
  }

  private returnToHomeFromBack(actionId: number): void {
    try {
      this.webController.loadUrl('about:blank');
    } catch (_) {
    }
    this.currentUrl = '';
    this.addressInput = '';
    this.updateCurrentTab('');
    this.showNavToastOnce(actionId, '已回到主页');
  }

  private showNavToastOnce(actionId: number, message: string): void {
    if (actionId <= 0) {
      this.showToast(message);
      return;
    }
    if (this.navToastShownForActionId === actionId) {
      return;
    }
    this.navToastShownForActionId = actionId;
    this.showToast(message);
  }

  private goForward(): void {
    try {
      if (!this.canGoForward()) {
        this.statusText = '已经是最新一页';
        return;
      }
      this.webController.forward();
      this.showToast('已前进');
    } catch (_) {
      this.statusText = '无法前进';
    }
  }

  @Builder
  private BookmarkPanel() {
    Column({ space: 12 }) {
      Text('书签管理')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .textAlign(TextAlign.Center)

      Row({ space: 8 }) {
        Select(this.toSelectOptions(this.bookmarkFolders))
          .selected(this.getSelectedFolderIndex())
          .value(this.selectedFolderName)
          .width('40%')
          .onSelect((index: number, value?: string) => {
            this.selectedFolderName = value ?? this.bookmarkFolders[index];
          })

        TextInput({ text: this.newFolderName, placeholder: '新建文件夹' })
          .layoutWeight(1)
          .height(40)
          .borderRadius(8)
          .backgroundColor('#F2F3F5')
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.newFolderName = value;
          })

        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(14)
            .fontColor(['#FFFFFF'])
        }
        .width(36)
        .height(36)
        .backgroundColor('#007DFF')
        .borderRadius(18)
        .onClick(() => {
          this.createFolder();
        })
      }
      .width('100%')

      if (this.showBackupPanel) {
        this.BackupPanel()
      }

      this.FolderManagePanel()

      if (this.filteredBookmarks().length === 0) {

      } else {
        List({ space: 8 }) {
          ForEach(this.filteredBookmarks(), (item: Bookmark) => {
            ListItem() {
              Column({ space: 8 }) {
                if (this.editingBookmarkId === item.id) {
                  Column({ space: 8 }) {
                    TextInput({ text: this.editingBookmarkTitle, placeholder: '书签标题' })
                      .height(40)
                      .borderRadius(8)
                      .backgroundColor('#F2F3F5')
                      .padding({ left: 12, right: 12 })
                      .onChange((value: string) => {
                        this.editingBookmarkTitle = value;
                      })

                    TextInput({ text: this.editingBookmarkUrl, placeholder: '书签地址（https://...）' })
                      .height(40)
                      .borderRadius(8)
                      .backgroundColor('#F2F3F5')
                      .padding({ left: 12, right: 12 })
                      .onChange((value: string) => {
                        this.editingBookmarkUrl = value;
                      })

                    Select(this.toSelectOptions(this.bookmarkFolders))
                      .selected(this.getSelectedFolderIndexForEdit())
                      .value(this.getFolderNameById(this.selectedFolderIdForEdit))
                      .width('100%')
                      .onSelect((index: number, value?: string) => {
                        const folderName = value ?? this.bookmarkFolders[index];
                        this.selectedFolderIdForEdit = this.getFolderIdByName(folderName);
                      })

                    Row({ space: 4 }) {
                      Button({ type: ButtonType.Normal }) {
                        SymbolGlyph($r('sys.symbol.trash'))
                          .fontSize(12)
                          .fontColor(['#FF4757'])
                      }
                      .layoutWeight(1)
                      .height(30)
                      .backgroundColor('#FFF0F0')
                      .borderRadius(6)
                      .onClick(() => {
                        this.deleteBookmark(item.id);
                      })
                      Button({ type: ButtonType.Normal }) {
                        SymbolGlyph($r('sys.symbol.checkmark'))
                          .fontSize(12)
                          .fontColor(['#FFFFFF'])
                      }
                      .layoutWeight(1)
                      .height(30)
                      .backgroundColor('#007DFF')
                      .borderRadius(6)
                      .onClick(() => {
                        this.saveEditedBookmark(item);
                      })
                      Button({ type: ButtonType.Normal }) {
                        SymbolGlyph($r('sys.symbol.xmark'))
                          .fontSize(12)
                          .fontColor(['#666666'])
                      }
                      .layoutWeight(1)
                      .height(30)
                      .backgroundColor('#F2F3F5')
                      .borderRadius(6)
                      .onClick(() => {
                        this.cancelEditingBookmark();
                      })
                    }
                  }
                  .padding(12)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(12)
                  .border({ width: 1, color: '#E8E8E8' })
                } else {
                  Row({ space: 8 }) {
                    Image(item.favicon || this.getSiteIcon(item.url))
                      .width(20)
                      .height(20)
                      .borderRadius(4)
                      .alt($r('app.media.app_icon'))
                    
                    Column({ space: 2 }) {
                      Text(item.title)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .width('100%')
                      Text(item.url)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .fontSize(11)
                        .fontColor('#999999')
                        .width('100%')
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    
                    Button({ type: ButtonType.Normal }) {
                      SymbolGlyph($r('sys.symbol.square_and_pencil'))
                        .fontSize(12)
                        .fontColor(['#666666'])
                    }
                    .width(32)
                    .height(32)
                    .backgroundColor('#F2F3F5')
                    .borderRadius(16)
                    .onClick(() => {
                      this.startEditingBookmark(item);
                    })
                  }
                  .width('100%')
                  .padding(10)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(8)
                  .onClick(() => {
                    this.currentUrl = item.url;
                    this.addressInput = item.url;
                    this.webController.loadUrl(item.url);
                    this.showBookmarks = false;
                  })
                }
              }
            }
          }, (item: Bookmark) => item.id + '_' + item.title + '_' + item.url)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
      }

      Row({ space: 8 }) {
        Button('添加当前页')
          .layoutWeight(1)
          .height(44)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor('#007DFF')
          .borderRadius(8)
          .onClick(() => {
            if (this.currentUrl) {
              this.saveBookmark();
            }
          })

      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor('#F7F8FA')
  }

  @Builder
  private BackupPanel() {
    Column({ space: 6 }) {
      Text('书签导入/导出（JSON）')
        .fontSize(12)
        .fontColor('#666666')
        .width('100%')

      Row({ space: 8 }) {
        Button('导出JSON')
          .fontSize(12)
          .onClick(() => {
            this.exportBookmarksAsJson();
          })

        Button('导入JSON')
          .fontSize(12)
          .onClick(() => {
            this.importBookmarksFromJson();
          })

        Button('清空文本')
          .fontSize(12)
          .onClick(() => {
            this.backupJsonText = '';
          })
      }
      .width('100%')

      TextInput({ text: this.backupJsonText, placeholder: '导出后可复制；或粘贴 JSON 后点“导入JSON”' })
        .height(140)
        .onChange((value: string) => {
          this.backupJsonText = value;
        })
    }
    .width('100%')
    .padding(8)
    .borderRadius(8)
    .backgroundColor('#EFFAF2')
  }

  @Builder
  private FolderManagePanel() {
    Column({ space: 6 }) {
      Text('文件夹管理')
        .fontSize(12)
        .fontColor('#666666')
        .width('100%')

      if (this.bookmarkFolderItems.length === 0) {
        Text('暂无自定义文件夹')
          .fontSize(12)
          .fontColor(Color.Gray)
          .width('100%')
      } else {
        ForEach(this.bookmarkFolderItems, (folder: BookmarkFolder) => {
          Row({ space: 8 }) {
            if (this.editingFolderId === folder.id) {
              TextInput({ text: this.editingFolderName, placeholder: '输入新文件夹名称' })
                .layoutWeight(1)
                .height(32)
                .backgroundColor('#F2F3F5')
                .borderRadius(8)
                .padding({ left: 10, right: 10 })
                .onChange((value: string) => {
                  this.editingFolderName = value;
                })

              Button({ type: ButtonType.Normal }) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(12)
                  .fontColor(['#FFFFFF'])
              }
              .width(28)
              .height(28)
              .backgroundColor('#007DFF')
              .borderRadius(14)
              .onClick(() => {
                this.saveEditingFolder(folder);
              })

              Button({ type: ButtonType.Normal }) {
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(12)
                  .fontColor(['#666666'])
              }
              .width(28)
              .height(28)
              .backgroundColor('#F2F3F5')
              .borderRadius(14)
              .onClick(() => {
                this.cancelEditingFolder();
              })
            } else {
              Text(folder.name)
                .layoutWeight(1)
                .fontSize(12)
                .onClick(() => {
                  this.selectFolderById(folder.id);
                })

              Button({ type: ButtonType.Normal }) {
                SymbolGlyph($r('sys.symbol.square_and_pencil'))
                  .fontSize(12)
                  .fontColor(['#666666'])
              }
              .width(28)
              .height(28)
              .backgroundColor('#F2F3F5')
              .borderRadius(14)
              .onClick(() => {
                this.startEditingFolder(folder);
              })

              Button({ type: ButtonType.Normal }) {
                SymbolGlyph($r('sys.symbol.trash'))
                  .fontSize(12)
                  .fontColor(['#FF4757'])
              }
              .width(28)
              .height(28)
              .backgroundColor('#FFF0F0')
              .borderRadius(14)
              .onClick(() => {
                this.deleteFolderById(folder.id);
              })
            }
          }
          .width('100%')
        }, (folder: BookmarkFolder) => folder.id)
      }
    }
    .width('100%')
    .padding(8)
    .borderRadius(8)
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#EDEDED' })
  }

  @Builder
  private HistoryPanel() {
    Column({ space: 12 }) {
      Text('浏览历史')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .textAlign(TextAlign.Center)

      TextInput({ text: this.historyKeyword, placeholder: '搜索历史（标题/URL）' })
        .height(44)
        .border({ width: 1, color: '#E8E8E8' })
        .borderRadius(8)
        .padding({ left: 12, right: 12 })
        .onChange((value: string) => {
          this.historyKeyword = value;
          this.loadHistoryRecords();
        })

      if (this.filteredHistoryRecords().length === 0) {

      } else {
        List({ space: 4 }) {
          ForEach(this.filteredHistoryRecords(), (item: HistoryRecord) => {
            ListItem() {
              Row({ space: 8 }) {
                Image(this.getSiteIcon(item.url))
                  .width(20)
                  .height(20)
                  .borderRadius(4)
                  .alt($r('app.media.app_icon'))
                
                Column({ space: 2 }) {
                  Text(item.title)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Row({ space: 4 }) {
                    Text(item.url)
                      .fontSize(11)
                      .fontColor('#999999')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    Text(this.formatHistoryTime(item.visitedAt))
                      .fontSize(11)
                      .fontColor('#BBBBBB')
                  }
                  .width('100%')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                
                Button({ type: ButtonType.Normal }) {
                  SymbolGlyph($r('sys.symbol.trash'))
                    .fontSize(12)
                    .fontColor(['#FF4757'])
                }
                .width(28)
                .height(28)
                .backgroundColor('#FFF0F0')
                .borderRadius(14)
                .onClick(() => {
                  this.deleteHistoryRecord(item.id);
                })
              }
              .width('100%')
              .padding(10)
              .backgroundColor('#FFFFFF')
              .borderRadius(8)
              .onClick(() => {
                this.currentUrl = item.url;
                this.addressInput = item.url;
                this.openByInput();
                this.showHistoryPanel = false;
              })
            }
          }, (item: HistoryRecord) => item.id)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
      }

      Row({ space: 8 }) {
        Button('清空历史')
          .layoutWeight(1)
          .height(44)
          .fontSize(14)
          .fontColor('#FF4444')
          .backgroundColor('#FFF0F0')
          .borderRadius(8)
          .onClick(() => {
            this.clearHistoryRecords();
          })

      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor('#F7F8FA')
  }

  @Builder
  private SyncPanel() {
    Column({ space: 12 }) {
      Column({ space: 10 }) {
          Text('WebDAV 同步')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1A1A1A')
            .width('100%')
            .textAlign(TextAlign.Center)

          Text('数据目录固定为 /小舟：书签在「书签」文件夹，笔记在「笔记」文件夹（测试连接会尝试创建 /小舟）')
            .fontSize(11)
            .fontColor('#888888')
            .width('100%')

          if (this.syncBusy) {
            Text(this.syncBusyText.length > 0 ? this.syncBusyText : '同步任务进行中...')
              .fontSize(12)
              .fontColor('#1E5AA7')
              .width('100%')
              .textAlign(TextAlign.Center)
          }

          Row({ space: 8 }) {
            Text('服务器')
              .fontSize(13)
              .fontColor('#666666')
              .width(54)
            TextInput({ text: this.syncServerUrl, placeholder: 'https://...' })
              .layoutWeight(1)
              .height(44)
              .borderRadius(8)
              .padding({ left: 12, right: 12 })
              .backgroundColor('#F2F3F5')
              .onChange((value: string) => {
                this.syncServerUrl = value;
                this.syncDraftTouched = true;
              })
          }
          .width('100%')

          Row({ space: 8 }) {
            Text('用户名')
              .fontSize(13)
              .fontColor('#666666')
              .width(54)
            TextInput({ text: this.syncUsername, placeholder: '请输入用户名' })
              .layoutWeight(1)
              .height(44)
              .borderRadius(8)
              .padding({ left: 12, right: 12 })
              .backgroundColor('#F2F3F5')
              .onChange((value: string) => {
                this.syncUsername = value;
                this.syncDraftTouched = true;
              })
          }
          .width('100%')

          Row({ space: 8 }) {
            Text('密码')
              .fontSize(13)
              .fontColor('#666666')
              .width(54)
            TextInput({ text: this.syncPassword, placeholder: '请输入密码' })
              .layoutWeight(1)
              .height(44)
              .type(InputType.Password)
              .borderRadius(8)
              .padding({ left: 12, right: 12 })
              .backgroundColor('#F2F3F5')
              .onChange((value: string) => {
                this.syncPassword = value;
                this.syncDraftTouched = true;
              })
          }
          .width('100%')

          Divider()
            .height(1)
            .color('#E8E8E8')
            .width('100%')

          Row({ space: 8 }) {
            Button(this.autoSyncOnLaunch ? '启动同步 开' : '启动同步 关')
              .layoutWeight(1)
              .height(34)
              .fontSize(12)
              .fontColor(this.autoSyncOnLaunch ? '#007DFF' : '#666666')
              .backgroundColor(this.autoSyncOnLaunch ? '#E8F4FF' : '#F2F3F5')
              .borderRadius(8)
              .enabled(!this.syncBusy)
              .onClick(() => {
                this.autoSyncOnLaunch = !this.autoSyncOnLaunch;
                // "同步全文" 功能并入 "启动同步"
                this.syncImportFullContent = this.autoSyncOnLaunch;
                this.saveWebDavConfig(true);
              })

            Button(this.autoSyncOnChange ? '变更同步 开' : '变更同步 关')
              .layoutWeight(1)
              .height(34)
              .fontSize(12)
              .fontColor(this.autoSyncOnChange ? '#007DFF' : '#666666')
              .backgroundColor(this.autoSyncOnChange ? '#E8F4FF' : '#F2F3F5')
              .borderRadius(8)
              .enabled(!this.syncBusy)
              .onClick(() => {
                this.autoSyncOnChange = !this.autoSyncOnChange;
                this.saveWebDavConfig(true);
              })
          }
          .width('100%')

          Row({ space: 8 }) {
            Button('保存配置')
              .layoutWeight(1)
              .height(36)
              .fontSize(13)
              .fontColor('#FFFFFF')
              .backgroundColor('#007DFF')
              .borderRadius(8)
              .enabled(!this.syncBusy)
              .onClick(() => {
                this.saveWebDavConfig();
              })

            Button('测试连接')
              .layoutWeight(1)
              .height(36)
              .fontSize(13)
              .fontColor('#007DFF')
              .backgroundColor('#E8F4FF')
              .borderRadius(8)
              .enabled(!this.syncBusy)
              .onClick(() => {
                this.testWebDavConnection();
              })
          }
          .width('100%')

          Row({ space: 8 }) {
            Button('立即同步')
              .layoutWeight(2)
              .height(36)
              .fontSize(13)
              .fontColor('#FFFFFF')
              .backgroundColor('#007DFF')
              .borderRadius(8)
              .enabled(!this.syncBusy)
              .onClick(() => {
                this.manualSyncAll();
              })
          }
          .width('100%')

          this.SyncLogPanel()
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, bottom: 16, top: 16 })
    .backgroundColor('#F7F8FA')
  }

  @Builder
  private SyncLogPanel() {
    Column({ space: 4 }) {
      Text('同步日志')
        .fontSize(12)
        .fontColor('#666666')
        .width('100%')

      if (this.lastSyncErrorDetail.length > 0) {
        Text(`最近错误：${this.lastSyncErrorDetail}`)
          .fontSize(12)
          .fontColor('#C5221F')
          .width('100%')
          .maxLines(4)
      }

      if (this.syncLogs.length === 0) {
        Text('暂无同步记录')
          .fontSize(12)
          .fontColor(Color.Gray)
          .width('100%')
      } else {
        List({ space: 4 }) {
          ForEach(this.syncLogs, (log: SyncLog) => {
            ListItem() {
              Row({ space: 8 }) {
                Text(log.timeLabel)
                  .fontSize(11)
                  .fontColor('#888888')

                Text(log.message)
                  .fontSize(12)
                  .fontColor(log.success ? '#0A7E07' : '#C5221F')
                  .layoutWeight(1)
                  .maxLines(3)
              }
              .width('100%')
            }
          }, (log: SyncLog) => log.id)
        }
        .height(140)
      }
    }
    .width('100%')
    .padding({ bottom: 8 })
  }

  // ----- 快捷笔记 -----

  private openQuickNote(): void {
    const currentTab = this.getCurrentTab();
    this.quickNoteTitle = currentTab?.title || '';
    this.quickNoteContent = '';
    this.showQuickNote = true;
  }

  private async saveQuickNote(): Promise<void> {
    if (!this.noteRepo) {
      promptAction.showToast({ message: '笔记服务未初始化' });
      return;
    }
    const title = this.quickNoteTitle.trim() || '快捷笔记';
    const content = this.quickNoteContent.trim();
    if (content.length === 0) {
      promptAction.showToast({ message: '请输入笔记内容' });
      return;
    }
    const now = Date.now();
    const currentTab = this.getCurrentTab();
    const note: Note = {
      id: 'note_' + now + '_' + Math.random().toString(36).substring(2, 8),
      type: 'manual',
      title: title,
      content: content,
      contentPlain: content.replace(/[#*`>\-\[\]()!]/g, '').substring(0, 200),
      sourceUrl: currentTab?.url || undefined,
      sourceTitle: currentTab?.title || undefined,
      tags: [],
      isFavorite: false,
      readProgress: 0,
      createdAt: now,
      updatedAt: now,
      deletedFlag: false
    };
    try {
      await this.noteRepo.upsertNote(note);
      this.showQuickNote = false;
      this.quickNoteContent = '';
      promptAction.showToast({ message: '笔记已保存' });
    } catch (_) {
      promptAction.showToast({ message: '保存失败' });
    }
  }

  // ----- 保存当前页面为笔记 -----

  private async saveCurrentPageAsNote(): Promise<void> {
    if (!this.noteRepo) {
      promptAction.showToast({ message: '笔记服务未初始化' });
      return;
    }
    const currentTab = this.getCurrentTab();
    if (!currentTab || !currentTab.url) {
      promptAction.showToast({ message: '没有打开的页面' });
      return;
    }
    try {
      const selectedText = await this.webController.runJavaScript('window.getSelection().toString()') as string;
      const now = Date.now();
      const contentParts: string[] = [];
      if (currentTab.title) {
        contentParts.push('> 来源：[' + currentTab.title + '](' + currentTab.url + ')');
      } else {
        contentParts.push('> 来源：' + currentTab.url);
      }
      contentParts.push('');
      if (selectedText && selectedText.trim().length > 0) {
        contentParts.push('> ' + selectedText.trim().split('\n').join('\n> '));
        contentParts.push('');
      }
      contentParts.push('---');
      contentParts.push('');
      contentParts.push('*于 ' + new Date().toLocaleString() + ' 保存*');

      const content = contentParts.join('\n');
      const plainText = (currentTab.title + ' ' + (selectedText || '')).substring(0, 200);

      const note: Note = {
        id: 'note_' + now + '_' + Math.random().toString(36).substring(2, 8),
        type: 'web_clip',
        title: currentTab.title || '未命名页面',
        content: content,
        contentPlain: plainText,
        sourceUrl: currentTab.url,
        sourceTitle: currentTab.title,
        tags: ['网页摘录'],
        // "摘录" 目录已移除，默认落到“全部”
        folderId: undefined,
        isFavorite: false,
        readProgress: 0,
        createdAt: now,
        updatedAt: now,
        deletedFlag: false
      };
      await this.noteRepo.upsertNote(note);
      promptAction.showToast({ message: '已保存为笔记' });
    } catch (_) {
      promptAction.showToast({ message: '保存失败' });
    }
  }

  @Builder
  private QuickNotePanel() {
    Stack() {
      // 半透明遮罩
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.4)')
        .onClick(() => {
          this.showQuickNote = false;
        })

      // 浮窗内容
      Column() {
        // 顶栏
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.square_and_pencil'))
            .fontSize(18)
            .fontColor(['#FF6600'])
          Text('快捷笔记')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1A1A1A')
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(18)
            .fontColor(['#999999'])
            .onClick(() => {
              this.showQuickNote = false;
            })
        }
        .width('100%')
        .padding({ bottom: 12 })

        // 来源 URL
        if (this.currentUrl) {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.link'))
              .fontSize(12)
              .fontColor(['#999999'])
            Text(this.currentUrl.length > 40 ? this.currentUrl.substring(0, 40) + '...' : this.currentUrl)
              .fontSize(12)
              .fontColor('#999999')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding({ bottom: 8 })
        }

        // 标题输入
        TextInput({ text: this.quickNoteTitle, placeholder: '标题（可选）' })
          .height(36)
          .width('100%')
          .backgroundColor('#F5F5F5')
          .borderRadius(8)
          .placeholderFont({ size: 14 })
          .placeholderColor('#CCCCCC')
          .fontSize(14)
          .padding({ left: 8, right: 8 })
          .onChange((value: string) => {
            this.quickNoteTitle = value;
          })

        // 内容输入
        TextArea({ text: this.quickNoteContent, placeholder: '记录你的想法...' })
          .height(160)
          .width('100%')
          .backgroundColor('#F5F5F5')
          .borderRadius(8)
          .placeholderFont({ size: 14 })
          .placeholderColor('#CCCCCC')
          .fontSize(14)
          .padding(8)
          .margin({ top: 8 })
          .onChange((value: string) => {
            this.quickNoteContent = value;
          })

        // 操作按钮
        Row({ space: 12 }) {
          Button('取消')
            .fontSize(14)
            .fontColor('#666666')
            .height(36)
            .layoutWeight(1)
            .backgroundColor('#F0F0F0')
            .borderRadius(18)
            .onClick(() => {
              this.showQuickNote = false;
            })

          Button('保存')
            .fontSize(14)
            .fontColor('#FFFFFF')
            .height(36)
            .layoutWeight(1)
            .backgroundColor('#FF6600')
            .borderRadius(18)
            .onClick(() => {
              this.saveQuickNote();
            })
        }
        .width('100%')
        .padding({ top: 12 })
      }
      .width('88%')
      .padding(20)
      .backgroundColor('#FFFFFF')
      .borderRadius(16)
      .shadow({
        radius: 12,
        color: 'rgba(0, 0, 0, 0.15)',
        offsetX: 0,
        offsetY: 4
      })
    }
    .width('100%')
    .height('100%')
  }

  private get readingBgColor(): string {
    if (this.readingBgMode === 'white') return '#FFFFFF';
    if (this.readingBgMode === 'gray') return '#F0F0F0';
    if (this.readingBgMode === 'dark') return '#1A1A2E';
    return '#F5F0E8';
  }

  private get readingTextColor(): string {
    return this.readingBgMode === 'dark' ? '#E0E0E0' : '#1A1A1A';
  }

  // ----- 阅读模式 -----

  private async toggleReadingMode(): Promise<void> {
    if (this.showReadingMode) {
      this.showReadingMode = false;
      return;
    }
    if (!this.currentUrl) {
      promptAction.showToast({ message: '没有打开的页面' });
      return;
    }
    try {
      promptAction.showToast({ message: '正在提取正文...' });
      const readabilityJs = `
(function() {
  function getContent() {
    var article = { title: document.title, content: '' };
    var selectors = [
      'article',
      '[role="main"]',
      '.post-content', '.article-content', '.entry-content',
      '.post-body', '.article-body',
      '#content', '#article',
      '.content', '.main-content',
      'main'
    ];
    var el = null;
    for (var i = 0; i < selectors.length; i++) {
      var found = document.querySelector(selectors[i]);
      if (found && found.textContent.length > 200) {
        el = found;
        break;
      }
    }
    if (!el) {
      var paragraphs = document.querySelectorAll('p');
      var buffer = '';
      for (var j = 0; j < paragraphs.length; j++) {
        if (paragraphs[j].textContent.trim().length > 20) {
          buffer += paragraphs[j].outerHTML + '\\n';
        }
      }
      if (buffer.length > 200) {
        return JSON.stringify({ title: document.title, content: buffer });
      }
    }
    if (el) {
      return JSON.stringify({ title: document.title, content: el.innerHTML });
    }
    return JSON.stringify({ title: document.title, content: document.body.innerText.substring(0, 5000) });
  }
  return getContent();
})();
`;
      const result: string = await this.webController.runJavaScript(readabilityJs) as string;
      interface ParsedResult {
        title?: string;
        content?: string;
      }
      const parsed: ParsedResult = JSON.parse(result);
      this.readingTitle = parsed.title || '阅读模式';
      this.readingContent = parsed.content || '无法提取正文内容';
      this.showReadingMode = true;
    } catch (_) {
      this.readingTitle = this.getCurrentTab()?.title || '阅读模式';
      this.readingContent = '无法提取正文内容';
      this.showReadingMode = true;
    }
  }

  private async saveReadingAsNote(): Promise<void> {
    if (!this.noteRepo) {
      promptAction.showToast({ message: '笔记服务未初始化' });
      return;
    }
    const now = Date.now();
    const plain = this.readingContent.replace(/<[^>]+>/g, '').substring(0, 200);
    const note: Note = {
      id: 'note_' + now + '_' + Math.random().toString(36).substring(2, 8),
      type: 'web_clip',
      title: this.readingTitle,
      content: this.readingContent,
      contentPlain: plain,
      sourceUrl: this.currentUrl || undefined,
      sourceTitle: this.readingTitle,
      tags: ['网页摘录'],
      isFavorite: false,
      readProgress: 0,
      createdAt: now,
      updatedAt: now,
      deletedFlag: false
    };
    try {
      await this.noteRepo.upsertNote(note);
      promptAction.showToast({ message: '已保存为笔记' });
    } catch (_) {
      promptAction.showToast({ message: '保存失败' });
    }
  }

  private stripHtml(html: string): string {
    return html
      .replace(/<script[^>]*>[\s\S]*?<\/script>/gi, '')
      .replace(/<style[^>]*>[\s\S]*?<\/style>/gi, '')
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<p[^>]*>/gi, '\n\n')
      .replace(/<\/p>/gi, '')
      .replace(/<h[1-6][^>]*>/gi, '\n\n')
      .replace(/<\/h[1-6]>/gi, '\n\n')
      .replace(/<li[^>]*>/gi, '\n- ')
      .replace(/<\/li>/gi, '')
      .replace(/<[^>]+>/g, '')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&nbsp;/g, ' ')
      .replace(/\n{4,}/g, '\n\n\n')
      .trim();
  }

  @Builder
  private ReadingModePanel() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.readingBgColor)

      Column() {
        Row({ space: 8 }) {
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(18)
              .fontColor(['#666666'])
          }
          .width(36)
          .height(36)
          .backgroundColor(this.readingBgMode === 'dark' ? '#333333' : '#F0F0F0')
          .borderRadius(18)
          .onClick(() => {
            this.showReadingMode = false;
          })

          Text(this.readingTitle)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.readingTextColor)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.textformat'))
              .fontSize(16)
              .fontColor(['#666666'])
          }
          .width(36)
          .height(36)
          .backgroundColor(this.readingBgMode === 'dark' ? '#333333' : '#F0F0F0')
          .borderRadius(18)
          .onClick(() => {
            const modes = ['paper', 'white', 'gray', 'dark'];
            const idx = modes.indexOf(this.readingBgMode);
            this.readingBgMode = modes[(idx + 1) % modes.length];
          })

          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.square_and_arrow_down'))
              .fontSize(16)
              .fontColor(['#007DFF'])
          }
          .width(36)
          .height(36)
          .backgroundColor(this.readingBgMode === 'dark' ? '#1A3A5C' : '#E8F4FF')
          .borderRadius(18)
          .onClick(() => {
            this.saveReadingAsNote();
          })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })

        Row({ space: 12 }) {
          Text('A')
            .fontSize(14)
            .fontColor('#999999')
            .fontWeight(FontWeight.Lighter)
          Slider({
            value: this.readingFontSize,
            min: 12,
            max: 28,
            step: 1
          })
            .width(120)
            .onChange((value: number) => {
              this.readingFontSize = value;
            })
          Text('A')
            .fontSize(18)
            .fontColor('#999999')
            .fontWeight(FontWeight.Bold)
          Text(this.readingFontSize + 'sp')
            .fontSize(12)
            .fontColor('#999999')
            .width(40)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 4 })

        Scroll() {
          Column() {
            Text(this.readingTitle)
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.readingTextColor)
              .width('100%')
              .padding({ bottom: 16 })

            Text(this.stripHtml(this.readingContent))
              .fontSize(this.readingFontSize)
              .fontColor(this.readingTextColor)
              .lineHeight(this.readingFontSize * this.readingLineHeight)
              .width('100%')
          }
          .padding({ left: 20, right: 20, top: 16, bottom: 40 })
        }
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  private toNavigableUrl(raw: string): string {
    const trimmed = raw.trim();

    // 检查是否已有协议
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      // 确保使用 HTTPS
      const url = trimmed.replace('http://', 'https://');
      // 规范化 URL
      return this.normalizeUrl(url);
    }

    // 处理带点的域名
    if (trimmed.includes('.')) {
      // 添加 HTTPS 协议
      const url = `https://${trimmed}`;
      // 规范化 URL
      return this.normalizeUrl(url);
    }

    // 处理搜索查询
    return `https://www.baidu.com/s?wd=${encodeURIComponent(trimmed)}`;
  }

  private normalizeUrl(urlStr: string): string {
    try {
      // 解析 URL
      const parsed = url.URL.parseURL(urlStr);

      // 获取各部分
      let hostname = parsed.hostname;
      let pathname = parsed.pathname;

      // 对于常见网站，添加 www 子域名
      const commonDomains = ['baidu.com', 'google.com', 'bing.com', 'yahoo.com', 'sina.com', 'sohu.com', 'qq.com'];
      if (commonDomains.includes(hostname) && !hostname.startsWith('www.')) {
        hostname = `www.${hostname}`;
      }

      // 确保路径以 / 结尾
      if (pathname === '') {
        pathname = '/';
      }

      // 重新构建 HTTPS URL
      return `https://${hostname}${pathname}${parsed.search}`;
    } catch {
      // 如果解析失败，返回原始 URL
      return urlStr;
    }
  }

  private saveBookmark(): void {
    if (this.bookmarkRepository === null) {
      this.statusText = '书签模块未初始化';
      return;
    }
    const selectedFolderId = this.getFolderIdByName(this.selectedFolderName);

    // 检查全局范围内是否已存在相同 URL 的书签（确保快捷访问不重复）
    const existingBookmarkGlobal = this.bookmarks.find((item: Bookmark) => {
      return item.url === this.currentUrl && !item.deletedFlag;
    });

    if (existingBookmarkGlobal !== undefined) {
      const existingFolderName = this.getFolderNameById(existingBookmarkGlobal.folderId ?? '');
      this.statusText = `该网站已收藏在"${existingFolderName}"文件夹`;
      this.showToast('该网站已收藏，无需重复添加');
      return;
    }

    // 通过 JavaScript 获取页面真实标题
    try {
      this.webController.runJavaScript('document.title')
        .then((title: string) => {
          const cleanTitle = title.replace(/^"|"$/g, '');
          this.doSaveBookmark(cleanTitle || this.currentUrl, selectedFolderId);
        })
        .catch(() => {
          this.doSaveBookmark(this.getCurrentTab()?.title || this.currentUrl, selectedFolderId);
        });
    } catch (_) {
      this.doSaveBookmark(this.getCurrentTab()?.title || this.currentUrl, selectedFolderId);
    }
  }

  private doSaveBookmark(title: string, folderId: string): void {
    if (this.bookmarkRepository === null) {
      return;
    }
    
    // 获取当前页面的 favicon
    const currentFavicon = this.getCurrentTab()?.favicon || this.getSiteIcon(this.currentUrl);
    
    const bookmark: Bookmark = {
      id: `${Date.now()}`,
      title: title,
      url: this.currentUrl,
      favicon: currentFavicon,
      folderId: folderId.length > 0 ? folderId : undefined,
      updatedAt: Date.now(),
      deletedFlag: false
    };

    // 立即更新本地状态，使UI立即生效
    this.bookmarks = [bookmark, ...this.bookmarks];
    this.calculateQuickAccess();
    // 递增版本号强制UI刷新
    this.bookmarkListVersion++;
    // 切换刷新标记
    this.bookmarkRefreshFlag = !this.bookmarkRefreshFlag;

    // 异步保存到存储
    this.bookmarkRepository.upsertBookmark(bookmark)
      .then(() => {
        this.statusText = '已加入书签';
        this.showToast('收藏成功');
        this.loadFolders();
        // 变更时自动同步
        if (this.autoSyncOnChange) {
          this.manualSyncAll(true);
        }
      })
      .catch(() => {
        this.statusText = '收藏失败';
        this.showToast('收藏失败');
        // 保存失败时移除刚添加的书签并重新加载
        this.bookmarks = this.bookmarks.filter(b => b.id !== bookmark.id);
        this.calculateQuickAccess();
        this.bookmarkListVersion++;
      });
  }

  private startEditingBookmark(item: Bookmark): void {
    this.editingBookmarkId = item.id;
    this.editingBookmarkTitle = item.title;
    this.editingBookmarkUrl = item.url;
    this.selectedFolderIdForEdit = item.folderId ?? '';
  }

  private cancelEditingBookmark(): void {
    this.editingBookmarkId = '';
    this.editingBookmarkTitle = '';
    this.editingBookmarkUrl = '';
  }

  private saveEditedBookmark(item: Bookmark): void {
    if (this.bookmarkRepository === null) {
      this.statusText = '书签模块未初始化';
      return;
    }
    const repository = this.bookmarkRepository;
    const nextTitle = this.editingBookmarkTitle.trim();
    const rawUrl = this.editingBookmarkUrl.trim();
    if (nextTitle.length === 0) {
      this.statusText = '书签标题不能为空';
      return;
    }
    if (rawUrl.length === 0) {
      this.statusText = '书签地址不能为空';
      return;
    }
    const nextUrl = this.toNavigableUrl(rawUrl);
    const nextBookmark: Bookmark = {
      id: item.id,
      title: nextTitle,
      url: nextUrl,
      folderId: this.selectedFolderIdForEdit.length > 0 ? this.selectedFolderIdForEdit : undefined,
      updatedAt: Date.now(),
      deletedFlag: false
    };

    // 立即更新本地状态，使UI立即生效
    const index = this.bookmarks.findIndex(b => b.id === item.id);
    if (index >= 0) {
      this.bookmarks[index] = nextBookmark;
      // 强制刷新
      this.bookmarks = [...this.bookmarks];
    }
    this.cancelEditingBookmark();
    this.calculateQuickAccess();
    // 递增版本号强制UI刷新
    this.bookmarkListVersion++;
    // 切换刷新标记
    this.bookmarkRefreshFlag = !this.bookmarkRefreshFlag;

    // 异步保存到存储
    repository.upsertBookmark(nextBookmark)
      .then(() => {
        this.statusText = '书签已更新';
        this.loadFolders();
        // 变更时自动同步
        if (this.autoSyncOnChange) {
          this.manualSyncAll(true);
        }
      })
      .catch(() => {
        this.statusText = '更新书签失败';
        // 保存失败时重新加载以恢复正确状态
        this.loadBookmarks();
        this.calculateQuickAccess();
      });
  }

  private deleteBookmark(bookmarkId: string): void {
    if (this.bookmarkRepository === null) {
      this.statusText = '书签模块未初始化';
      return;
    }

    // 立即更新本地状态，使UI立即生效
    const index = this.bookmarks.findIndex(b => b.id === bookmarkId);
    if (index >= 0) {
      this.bookmarks.splice(index, 1);
      // 强制刷新
      this.bookmarks = [...this.bookmarks];
    }
    this.calculateQuickAccess();
    // 递增版本号强制UI刷新
    this.bookmarkListVersion++;
    // 切换刷新标记
    this.bookmarkRefreshFlag = !this.bookmarkRefreshFlag;

    // 异步保存到存储
    this.bookmarkRepository.markBookmarkDeleted(bookmarkId)
      .then(() => {
        this.statusText = '书签已删除';
        // 变更时自动同步
        if (this.autoSyncOnChange) {
          this.manualSyncAll(true);
        }
      })
      .catch(() => {
        this.statusText = '删除书签失败';
        // 删除失败时重新加载以恢复正确状态
        this.loadBookmarks();
        this.calculateQuickAccess();
      });
  }

  private loadBookmarks(): void {
    if (this.bookmarkRepository === null) {
      this.bookmarks = [];
      return;
    }
    this.bookmarkRepository.listBookmarks(false)
      .then((items: Bookmark[]) => {
        this.bookmarks = items;
      })
      .catch(() => {
        this.statusText = '读取书签失败';
      });
  }

  private loadFolders(): void {
    if (this.bookmarkRepository === null) {
      this.bookmarkFolders = ['全部', '未分类'];
      return;
    }
    this.bookmarkRepository.listFolders()
      .then((folders) => {
        this.bookmarkFolderItems = folders;
        const names: string[] = ['全部', '未分类'];
        for (const folder of folders) {
          names.push(folder.name);
        }
        this.bookmarkFolders = names;
        if (!this.bookmarkFolders.includes(this.selectedFolderName)) {
          this.selectedFolderName = '全部';
        }
      })
      .catch(() => {
        this.statusText = '读取文件夹失败';
      });
  }

  private createFolder(): void {
    if (this.bookmarkRepository === null) {
      this.statusText = '书签模块未初始化';
      return;
    }
    const name = this.newFolderName.trim();
    if (name.length === 0) {
      this.statusText = '请输入文件夹名称';
      return;
    }
    if (name === '全部' || name === '未分类') {
      this.statusText = '该名称为系统保留';
      return;
    }
    if (this.bookmarkFolderItems.some((item: BookmarkFolder) => item.name === name)) {
      this.statusText = '文件夹名称已存在';
      return;
    }
    const folderId = `${Date.now()}_${Math.floor(Math.random() * 1000)}`;
    this.bookmarkRepository.upsertFolder({
      id: folderId,
      name: name,
      updatedAt: Date.now()
    })
      .then(() => {
        this.newFolderName = '';
        this.statusText = '文件夹已创建';
        this.selectedFolderName = name;
        this.loadFolders();
      })
      .catch(() => {
        this.statusText = '创建文件夹失败';
      });
  }

  private exportBookmarksAsJson(): void {
    if (this.bookmarkRepository === null) {
      this.statusText = '书签模块未初始化';
      return;
    }
    this.bookmarkRepository.getSnapshot()
      .then((snapshot: BookmarkSnapshot) => {
        this.backupJsonText = JSON.stringify(snapshot, null, 2);
        this.statusText = `导出成功：${snapshot.bookmarks.length} 条书签`;
      })
      .catch(() => {
        this.statusText = '导出失败';
      });
  }

  private importBookmarksFromJson(): void {
    if (this.bookmarkRepository === null) {
      this.statusText = '书签模块未初始化';
      return;
    }
    const raw = this.backupJsonText.trim();
    if (raw.length === 0) {
      this.statusText = '请先粘贴 JSON 内容';
      return;
    }
    let parsed: BookmarkSnapshot;
    try {
      parsed = JSON.parse(raw) as BookmarkSnapshot;
    } catch (_) {
      this.statusText = 'JSON 格式错误';
      return;
    }
    if (!Array.isArray(parsed.bookmarks) || !Array.isArray(parsed.folders)) {
      this.statusText = 'JSON 内容不符合书签快照格式';
      return;
    }
    const normalized: BookmarkSnapshot = {
      schemaVersion: parsed.schemaVersion ?? 1,
      folders: parsed.folders.map((folder: BookmarkFolder) => {
        const normalizedFolder: BookmarkFolder = {
          id: folder.id,
          name: folder.name,
          updatedAt: folder.updatedAt ?? Date.now()
        };
        return normalizedFolder;
      }),
      bookmarks: parsed.bookmarks.map((bookmark: Bookmark) => {
        const normalizedBookmark: Bookmark = {
          id: bookmark.id,
          title: bookmark.title,
          url: bookmark.url,
          folderId: bookmark.folderId,
          updatedAt: bookmark.updatedAt ?? Date.now(),
          deletedFlag: bookmark.deletedFlag ?? false
        };
        return normalizedBookmark;
      })
    };
    this.bookmarkRepository.setSnapshot(normalized)
      .then(() => {
        this.statusText = `导入成功：${normalized.bookmarks.length} 条书签`;
        this.loadFolders();
        this.loadBookmarks();
      })
      .catch(() => {
        this.statusText = '导入失败';
      });
  }

  private filteredBookmarks(): Bookmark[] {
    // 引用多个状态变量确保UI重新渲染
    const _ = this.bookmarkListVersion + (this.bookmarkRefreshFlag ? 1 : 0);
    let result: Bookmark[] = [];
    if (this.selectedFolderName === '全部') {
      result = this.bookmarks;
    } else if (this.selectedFolderName === '未分类') {
      result = this.bookmarks.filter((item: Bookmark) => item.folderId === undefined || item.folderId.length === 0);
    } else {
      const folderId = this.getFolderIdByName(this.selectedFolderName);
      if (folderId.length > 0) {
        result = this.bookmarks.filter((item: Bookmark) => item.folderId === folderId);
      } else {
        result = this.bookmarks;
      }
    }
    return [...result];
  }

  private startEditingFolder(folder: BookmarkFolder): void {
    this.editingFolderId = folder.id;
    this.editingFolderName = folder.name;
  }

  private cancelEditingFolder(): void {
    this.editingFolderId = '';
    this.editingFolderName = '';
  }

  private saveEditingFolder(folder: BookmarkFolder): void {
    if (this.bookmarkRepository === null) {
      this.statusText = '书签模块未初始化';
      return;
    }
    const nextName = this.editingFolderName.trim();
    if (nextName.length === 0) {
      this.statusText = '请输入新文件夹名称';
      return;
    }
    if (nextName === '全部' || nextName === '未分类') {
      this.statusText = '该名称为系统保留';
      return;
    }
    if (this.bookmarkFolderItems.some((item: BookmarkFolder) => item.id !== folder.id && item.name === nextName)) {
      this.statusText = '文件夹名称已存在';
      return;
    }
    this.bookmarkRepository.renameFolder(folder.id, nextName)
      .then((renamed: boolean) => {
        if (!renamed) {
          this.statusText = '重命名失败：文件夹不存在';
          return;
        }
        if (this.selectedFolderName === folder.name) {
          this.selectedFolderName = nextName;
        }
        this.statusText = '文件夹已重命名';
        this.cancelEditingFolder();
        this.loadFolders();
      })
      .catch(() => {
        this.statusText = '重命名文件夹失败';
      });
  }

  private deleteFolderById(folderId: string): void {
    if (this.bookmarkRepository === null) {
      this.statusText = '书签模块未初始化';
      return;
    }
    const target = this.bookmarkFolderItems.find((item: BookmarkFolder) => item.id === folderId);
    this.bookmarkRepository.deleteFolder(folderId)
      .then((deleted: boolean) => {
        if (!deleted) {
          this.statusText = '删除失败：文件夹不存在';
          return;
        }
        if (target !== undefined && this.selectedFolderName === target.name) {
          this.selectedFolderName = '未分类';
        }
        this.statusText = '文件夹已删除，书签已移入未分类';
        this.cancelEditingFolder();
        this.loadFolders();
        this.loadBookmarks();
      })
      .catch(() => {
        this.statusText = '删除文件夹失败';
      });
  }

  private selectFolderById(folderId: string): void {
    const target = this.bookmarkFolderItems.find((item: BookmarkFolder) => item.id === folderId);
    if (target === undefined) {
      return;
    }
    this.selectedFolderName = target.name;
  }

  private getFolderIdByName(folderName: string): string {
    if (folderName === '全部' || folderName === '未分类') {
      return '';
    }
    const target = this.bookmarkFolderItems.find((item) => item.name === folderName);
    return target?.id ?? '';
  }

  private getFolderNameById(folderId: string): string {
    if (folderId.length === 0) {
      return '未分类';
    }
    const target = this.bookmarkFolderItems.find((item) => item.id === folderId);
    return target?.name ?? '未分类';
  }

  private getSelectedFolderIndex(): number {
    const index = this.bookmarkFolders.findIndex((name) => name === this.selectedFolderName);
    return index >= 0 ? index : 0;
  }

  private getSelectedFolderIndexForEdit(): number {
    const folderName = this.getFolderNameById(this.selectedFolderIdForEdit);
    const index = this.bookmarkFolders.findIndex((name) => name === folderName);
    return index >= 0 ? index : 1;
  }

  private toSelectOptions(names: string[]): SelectOption[] {
    const options: SelectOption[] = [];
    for (const name of names) {
      options.push({ value: name });
    }
    return options;
  }

  private refreshPage(): void {
    try {
      this.webController.refresh();
    } catch (_) {
      this.statusText = '刷新失败';
    }
  }

  private initBookmarkRepository(): void {
    if (this.bookmarkRepository !== null) {
      return;
    }
    try {
      const uiContext = getContext(this) as common.UIAbilityContext;
      this.bookmarkRepository = new PreferencesBookmarkRepository(uiContext);
      this.webDavSyncService = new WebDavSyncService(this.bookmarkRepository);
      if (this.webDavSyncService && this.noteRepo) {
        this.webDavSyncService.setNoteRepository(this.noteRepo);
      }
      this.loadFolders();
    } catch (_) {
      this.statusText = '书签存储初始化失败';
    }
  }

  private initHistoryRepository(): void {
    if (this.historyRepository !== null) {
      return;
    }
    try {
      const uiContext = getContext(this) as common.UIAbilityContext;
      this.historyRepository = new PreferencesHistoryRepository(uiContext);
    } catch (_) {
      this.statusText = '历史模块初始化失败';
    }
  }

  private initWebDavConfigRepository(): void {
    if (this.webDavConfigRepository !== null) {
      return;
    }
    try {
      const uiContext = getContext(this) as common.UIAbilityContext;
      this.webDavConfigRepository = new PreferencesWebDavConfigRepository(uiContext);
    } catch (_) {
      this.statusText = '同步配置模块初始化失败';
    }
  }

  private initSyncLogRepository(): void {
    if (this.syncLogRepository !== null) {
      return;
    }
    try {
      const uiContext = getContext(this) as common.UIAbilityContext;
      this.syncLogRepository = new PreferencesSyncLogRepository(uiContext);
    } catch (_) {
      this.statusText = '同步日志模块初始化失败';
    }
  }

  private loadWebDavConfig(): void {
    if (this.webDavConfigRepository === null) {
      return;
    }
    this.webDavConfigRepository.getConfig()
      .then((config: WebDavConfig) => {
        // Avoid overwriting user's in-progress edits when async config loads.
        if (!this.syncDraftTouched) {
          this.syncServerUrl = config.serverUrl;
          this.syncUsername = config.username;
          this.syncPassword = config.password;
        }
        this.syncRemotePath = '/小舟/书签/bookmarks.json';
        this.syncNoteRemotePath = '/小舟/笔记';
        this.autoSyncOnLaunch = config.autoSyncOnLaunch;
        this.syncImportFullContent = config.syncImportFullContent ?? false;
        this.autoSyncOnChange = config.autoSyncOnChange || false;
        if (this.autoSyncOnLaunch) {
          this.appendSyncLog('检测到启动自动同步配置，开始执行同步', true);
          this.manualSyncAll(true);
        }
      })
      .catch(() => {
        this.statusText = '读取同步配置失败';
        this.appendSyncLog('读取同步配置失败', false);
      });
  }

  private saveWebDavConfig(silent: boolean = false): void {
    if (this.webDavConfigRepository === null) {
      this.statusText = '同步配置模块未初始化';
      if (!silent) {
        this.appendSyncLog('保存配置失败：同步配置模块未初始化', false);
      }
      return;
    }
    const validationMessage = this.validateSyncInputs();
    if (validationMessage.length > 0) {
      this.statusText = validationMessage;
      if (!silent) {
        this.appendSyncLog(`保存配置失败：${validationMessage}`, false);
      }
      return;
    }

    const config: WebDavConfig = {
      serverUrl: this.syncServerUrl.trim(),
      username: this.syncUsername.trim(),
      password: this.syncPassword,
      remotePath: '/小舟/书签/bookmarks.json',
      noteRemotePath: '/小舟/笔记',
      syncNotesEnabled: true,
      syncImportFullContent: this.syncImportFullContent ?? false,
      autoSyncOnLaunch: this.autoSyncOnLaunch,
      autoSyncOnChange: this.autoSyncOnChange
    };
    this.webDavConfigRepository.saveConfig(config)
      .then(() => {
        this.statusText = silent ? '自动同步设置已更新' : 'WebDAV 配置已保存';
        this.syncDraftTouched = false;
        if (!silent) {
          this.appendSyncLog('配置保存成功', true);
        }
      })
      .catch(() => {
        this.statusText = '保存同步配置失败';
        if (!silent) {
          this.appendSyncLog('配置保存失败', false);
        }
      });
  }

  private manualSyncAll(isAuto: boolean = false): void {
    if (this.syncBusy) {
      this.statusText = '已有同步任务在进行中，请稍候';
      return;
    }
    const validationMessage = this.validateSyncInputs();
    if (validationMessage.length > 0) {
      this.statusText = validationMessage;
      this.appendSyncLog(`${isAuto ? '自动' : '手动'}全量同步失败：${validationMessage}`, false);
      return;
    }
    if (this.webDavSyncService === null) {
      this.statusText = '同步服务未初始化';
      this.appendSyncLog(`${isAuto ? '自动' : '手动'}全量同步失败：同步服务未初始化`, false);
      return;
    }
    const config: WebDavConfig = {
      serverUrl: this.syncServerUrl.trim(),
      username: this.syncUsername.trim(),
      password: this.syncPassword,
      remotePath: '/小舟/书签/bookmarks.json',
      noteRemotePath: '/小舟/笔记',
      syncNotesEnabled: true,
      syncImportFullContent: this.syncImportFullContent,
      autoSyncOnLaunch: this.autoSyncOnLaunch,
      autoSyncOnChange: this.autoSyncOnChange
    };
    this.syncBusy = true;
    this.syncBusyText = isAuto ? '自动全量同步进行中...' : '全量同步进行中...';
    this.webDavSyncService.syncAll(config)
      .then((result: SyncExecutionResult) => {
        const prefix = isAuto ? '自动' : '手动';
        const message = `${prefix}全量同步：${result.message}`;
        this.statusText = message;
        this.appendSyncLog(message, result.success);
        this.loadBookmarks();
      })
      .catch((err: Object) => {
        const detail = this.errorToMessage(err);
        this.statusText = `${isAuto ? '自动' : '手动'}全量同步失败：${detail}`;
        this.appendSyncLog(`${isAuto ? '自动' : '手动'}全量同步失败：${detail}`, false);
      })
      .finally(() => {
        this.syncBusy = false;
        this.syncBusyText = '';
      });
  }

  private testWebDavConnection(): void {
    if (this.syncBusy) {
      this.statusText = '同步任务进行中，请稍后再测连接';
      return;
    }
    const validationMessage = this.validateSyncInputs();
    if (validationMessage.length > 0) {
      this.statusText = validationMessage;
      this.connectionStatusText = validationMessage;
      this.connectionStatusType = 'error';
      this.appendSyncLog(`连接测试失败：${validationMessage}`, false);
      return;
    }
    if (this.webDavSyncService === null) {
      this.statusText = '同步服务未初始化';
      this.connectionStatusText = '同步服务未初始化';
      this.connectionStatusType = 'error';
      this.appendSyncLog('连接测试失败：同步服务未初始化', false);
      return;
    }
    const config: WebDavConfig = {
      serverUrl: this.syncServerUrl.trim(),
      username: this.syncUsername.trim(),
      password: this.syncPassword,
      remotePath: '/小舟/书签/bookmarks.json',
      noteRemotePath: '/小舟/笔记',
      syncNotesEnabled: true,
      syncImportFullContent: this.syncImportFullContent,
      autoSyncOnLaunch: this.autoSyncOnLaunch,
      autoSyncOnChange: this.autoSyncOnChange
    };
    this.syncBusy = true;
    this.syncBusyText = '连接测试进行中...';
    this.webDavSyncService.testConnection(config)
      .then((result: ConnectionTestResult) => {
        this.statusText = `连接测试：${result.message}`;
        this.connectionStatusText = result.message;
        this.connectionStatusType = this.resolveConnectionStatusType(result);
        this.appendSyncLog(`连接测试：${result.message}`, result.success);
      })
      .catch((err: Object) => {
        const detail = this.errorToMessage(err);
        this.statusText = `连接测试失败：${detail}`;
        this.connectionStatusText = detail;
        this.connectionStatusType = 'error';
        this.appendSyncLog(`连接测试失败：${detail}`, false);
      })
      .finally(() => {
        this.syncBusy = false;
        this.syncBusyText = '';
      });
  }

  private resolveConnectionStatusType(result: ConnectionTestResult): string {
    if (result.success) {
      if (result.message.includes('不存在')) {
        return 'warn';
      }
      return 'success';
    }
    if (result.message.includes('409') || result.message.includes('路径')) {
      return 'warn';
    }
    return 'error';
  }

  private shouldIgnoreWebError(errorCode: number): boolean {
    // Common transient/resource errors that usually do not block final page render.
    return errorCode === -2   // NAME_NOT_RESOLVED (often transient during redirect)
      || errorCode === -302   // ERR_UNKNOWN_URL_SCHEME / redirect handoff variants
      || errorCode === -102   // ERR_CONNECTION_REFUSED (often subresource)
      || errorCode === -101   // ERR_CONNECTION_RESET
      || errorCode === -104;  // ERR_INTERNET_DISCONNECTED for subrequests
  }

  private connectionStatusColor(): string {
    if (this.connectionStatusType === 'success') {
      return '#0A7E07';
    }
    if (this.connectionStatusType === 'warn') {
      return '#B26A00';
    }
    if (this.connectionStatusType === 'error') {
      return '#C5221F';
    }
    return '#666666';
  }

  private validateSyncInputs(): string {
    const server = this.syncServerUrl.trim();
    const user = this.syncUsername.trim();
    if (server.length === 0) {
      return '请填写 WebDAV 服务器地址';
    }
    if (!server.startsWith('https://')) {
      return '服务器地址需以 https:// 开头';
    }
    if (user.length === 0) {
      return '请填写 WebDAV 用户名';
    }
    if (this.syncPassword.length === 0) {
      return '请填写 WebDAV 密码';
    }
    return '';
  }

  // 提取URL的origin（协议+域名），用于匹配书签
  private getUrlOrigin(url: string): string {
    const match = url.match(/^https?:\/\/[^/]+/);
    return match ? match[0] : '';
  }

  // 根据当前URL查找匹配的书签（按origin匹配，忽略query/fragment）
  private getCurrentBookmark(): Bookmark | null {
    const url = this.currentUrl;
    if (!url) return null;
    const origin = this.getUrlOrigin(url);
    if (!origin) return null;
    return this.bookmarks.find(b => !b.deletedFlag && this.getUrlOrigin(b.url) === origin) ?? null;
  }

  // 同步地址栏到WebView当前URL
  private syncAddressBarFromWebView(): void {
    try {
      const currentUrl = this.webController.getUrl();
      if (currentUrl && currentUrl.startsWith('http')) {
        this.currentUrl = currentUrl;
        // 如果有匹配书签（按origin匹配），地址栏显示书签标题；否则显示URL
        const origin = this.getUrlOrigin(currentUrl);
        const bm = origin ? this.bookmarks.find(b => !b.deletedFlag && this.getUrlOrigin(b.url) === origin) : null;
        this.addressInput = bm ? bm.title : currentUrl;
        // 更新当前页签的URL
        this.updateCurrentTab(currentUrl);
      }
    } catch (_) {
      // 忽略获取URL失败的情况
    }
  }

  private fetchFavicon(): void {
    if (this.activeTabId) {
      const currentTab = this.tabs.find((tab) => tab.id === this.activeTabId);
      if (currentTab && currentTab.url) {
        try {
          const jsCode = `
            (function() {
              var link = document.querySelector("link[rel='icon']") || 
                         document.querySelector("link[rel='shortcut icon']") ||
                         document.querySelector("link[rel='apple-touch-icon']");
              if (link && link.href) {
                return link.href;
              }
              // 如果没有找到，返回网站根目录的 favicon
              return window.location.origin + '/favicon.ico';
            })()
          `;
          this.webController.runJavaScript(jsCode)
            .then((faviconUrl: string) => {
              const cleanUrl = faviconUrl.replace(/^"|"$/g, '');
              if (cleanUrl && currentTab) {
                currentTab.favicon = cleanUrl;
              }
            })
            .catch(() => {});
        } catch (_) {}
      }
    }
  }

  private recordCurrentPageToHistory(): void {
    if (this.historyRepository === null) {
      return;
    }
    const url = this.currentUrl.trim();
    if (url.length === 0 || !url.startsWith('http')) {
      return;
    }
    
    // 获取页面真实标题
    let pageTitle = this.getCurrentTab()?.title || this.currentUrl;
    try {
      this.webController.runJavaScript('document.title')
        .then((title: string) => {
          const cleanTitle = title.replace(/^"|"$/g, '');
          this.doSaveHistoryRecord(cleanTitle || pageTitle, url);
        })
        .catch(() => {
          this.doSaveHistoryRecord(pageTitle, url);
        });
    } catch (_) {
      this.doSaveHistoryRecord(pageTitle, url);
    }
  }

  private doSaveHistoryRecord(title: string, url: string): void {
    if (this.historyRepository === null) {
      return;
    }
    const record: HistoryRecord = {
      id: `${Date.now()}_${Math.floor(Math.random() * 1000)}`,
      title: title,
      url: url,
      visitedAt: Date.now()
    };
    this.historyRepository.saveRecord(record)
      .then(() => {
        if (this.showHistoryPanel) {
          this.loadHistoryRecords();
        }
      })
      .catch(() => {
        this.statusText = '写入历史失败';
      });
  }

  private loadHistoryRecords(): void {
    if (this.historyRepository === null) {
      this.historyRecords = [];
      return;
    }
    this.historyRepository.listRecords()
      .then((items: HistoryRecord[]) => {
        this.historyRecords = items;
        // 重新计算智能快捷访问
        this.calculateQuickAccess();
      })
      .catch(() => {
        this.statusText = '读取历史失败';
      });
  }

  private filteredHistoryRecords(): HistoryRecord[] {
    const keyword = this.historyKeyword.trim().toLowerCase();
    if (keyword.length === 0) {
      return this.historyRecords;
    }
    return this.historyRecords.filter((item: HistoryRecord) => {
      return item.title.toLowerCase().includes(keyword) || item.url.toLowerCase().includes(keyword);
    });
  }

  private deleteHistoryRecord(recordId: string): void {
    if (this.historyRepository === null) {
      this.statusText = '历史模块未初始化';
      return;
    }
    this.historyRepository.deleteRecord(recordId)
      .then(() => {
        this.loadHistoryRecords();
        this.statusText = '历史记录已删除';
      })
      .catch(() => {
        this.statusText = '删除历史失败';
      });
  }

  private clearHistoryRecords(): void {
    const repository = this.historyRepository;
    if (repository === null) {
      this.statusText = '历史模块未初始化';
      return;
    }
    
    // 显示确认对话框
    promptAction.showDialog({
      title: '确认清空',
      message: '确定要清空所有历史记录吗？此操作不可恢复。',
      buttons: [
        {
          text: '取消',
          color: '#666666'
        },
        {
          text: '确定',
          color: '#FF4444'
        }
      ]
    }).then((result) => {
      if (result.index === 1) { // 确定按钮
        repository.clearAll()
          .then(() => {
            this.historyRecords = [];
            this.statusText = '历史记录已清空';
            promptAction.showToast({ message: '历史记录已清空' });
          })
          .catch(() => {
            this.statusText = '清空历史失败';
            promptAction.showToast({ message: '清空历史失败' });
          });
      }
    });
  }

  private formatHistoryTime(timestamp: number): string {
    const now = Date.now();
    const diff = now - timestamp;
    
    const minute = 60 * 1000;
    const hour = 60 * minute;
    const day = 24 * hour;
    
    if (diff < minute) {
      return '刚刚';
    } else if (diff < hour) {
      const minutes = Math.floor(diff / minute);
      return `${minutes}分钟前`;
    } else if (diff < day) {
      const hours = Math.floor(diff / hour);
      return `${hours}小时前`;
    } else {
      const days = Math.floor(diff / day);
      return `${days}天前`;
    }
  }

  private appendSyncLog(message: string, success: boolean): void {
    const now = new Date();
    const hh = `${now.getHours()}`.padStart(2, '0');
    const mm = `${now.getMinutes()}`.padStart(2, '0');
    const ss = `${now.getSeconds()}`.padStart(2, '0');
    const timeLabel = `${hh}:${mm}:${ss}`;
    const next: SyncLog[] = this.syncLogs.slice();
    next.unshift({
      id: `${Date.now()}_${Math.floor(Math.random() * 1000)}`,
      timeLabel: timeLabel,
      message: message,
      success: success
    });
    if (next.length > 20) {
      next.length = 20;
    }
    this.syncLogs = next;
    if (!success) {
      this.lastSyncErrorDetail = message;
    }
    this.persistSyncLogs();
  }

  private loadSyncLogs(): void {
    if (this.syncLogRepository === null) {
      return;
    }
    this.syncLogRepository.listLogs()
      .then((items: SyncLog[]) => {
        this.syncLogs = items.slice(0, 20);
      })
      .catch(() => {
        this.statusText = '读取同步日志失败';
      });
  }

  private persistSyncLogs(): void {
    if (this.syncLogRepository === null) {
      return;
    }
    this.syncLogRepository.saveLogs(this.syncLogs)
      .catch(() => {
        this.statusText = '保存同步日志失败';
      });
  }

  private openNoteListPage(): void {
    try {
      router.pushUrl({
        url: 'pages/NoteListPageSafe'
      }).then(() => {
        this.navigatingToNotes = false;
      }).catch((err: Object) => {
        this.navigatingToNotes = false;
        console.error('Failed to navigate to NoteListPageSafe (async):', this.errorToMessage(err));
        promptAction.showToast({ message: '页面跳转失败' });
      });
    } catch (err) {
      this.navigatingToNotes = false;
      console.error('Failed to navigate to NoteListPageSafe (sync):', this.errorToMessage(err));
      promptAction.showToast({ message: '页面跳转失败' });
    }
  }

  private errorToMessage(err: Object): string {
    const e = err as ErrorLike;
    let text = '';
    if (e.code !== undefined) {
      text += `code=${e.code}; `;
    }
    if (e.name !== undefined && e.name.length > 0) {
      text += `name=${e.name}; `;
    }
    if (e.message !== undefined && e.message.length > 0) {
      text += `message=${e.message}; `;
    }
    const trimmed = text.trim();
    if (trimmed.length > 0) {
      return trimmed;
    }
    const asString = `${err}`;
    if (asString.length > 0 && asString !== '[object Object]') {
      return asString;
    }
    const asJson = JSON.stringify(err);
    if (asJson.length > 0 && asJson !== '{}') {
      return asJson;
    }
    return '未知错误（异常对象无可读字段）';
  }

  private showToast(message: string): void {
    try {
      promptAction.showToast({ message: message, duration: 1500 });
    } catch (_) {
      this.statusText = message;
    }
  }
}
