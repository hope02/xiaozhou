import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Note, NoteFolder, NoteType } from '../model/Note';
import { NoteRepository } from '../repository/NoteRepository';
import { NOTE_FOLDER_IDS, PreferencesNoteRepository } from '../repository/PreferencesNoteRepository';
import { ImportProgress, ImportResult, NoteImportService } from '../service/NoteImportService';

interface DialogResult {
  index: number;
}

interface ErrorLike {
  message?: string;
  code?: number | string;
  name?: string;
}

/** 笔记详情页路由参数（须为显式类型，满足 arkts-no-untyped-obj-literals） */
interface NoteDetailRouteParams {
  noteId: string;
  isNew: string;
}

class FolderManagerParams {
  mode: string = 'select';
  selectedFolderId: string = '';
  noteId: string = '';
}

@Entry
@Component
struct NoteListPageSafe {
  @State notes: Note[] = [];
  @State displayNotes: Note[] = [];
  @State folders: NoteFolder[] = [];
  @State keyword: string = '';
  @State activeFilter: NoteType | 'all' = 'all';
  @State activeFolderId: string = '';
  @State selectedFolderId: string = '';
  @State sortMode: 'updated' | 'created' | 'title' = 'updated';
  @State statusText: string = '初始化中...';
  @State showTopActionMenu: boolean = false;
  @State showSearchBar: boolean = false;
  @State showAddMenu: boolean = false;
  @State showDeleteConfirm: boolean = false;
  @State deleteTargetNoteId: string = '';
  @State showImportDialog: boolean = false;
  @State importProgressStage: string = 'reading';
  @State importProgressPercent: number = 0;
  @State importProgressMessage: string = '';
  @State isImporting: boolean = false;
  private noteRepo: NoteRepository | null = null;
  private importService: NoteImportService | null = null;

  private syncFolderIdFromRouteParams(): void {
    // folderId may be an empty string meaning "all folders".
    // We must treat "folderId exists but empty" as a meaningful update to clear any previous filter.
    try {
      const params = router.getParams() as Record<string, string | undefined | null> | undefined | null;
      if (!params) return;
      const fid = params['folderId'];
      // Important: empty string '' is valid and means "all folders".
      if (typeof fid === 'string') {
        // Treat root folder as "all" to avoid filtering everything out.
        const next = fid === NOTE_FOLDER_IDS.root ? '' : fid;
        if (next !== this.selectedFolderId) {
          this.selectedFolderId = next;
        }
        if (next !== this.activeFolderId) {
          this.activeFolderId = next;
        }
      } else {
        // If folderId is missing, reset to "all" to avoid stale/invalid state.
        if (typeof this.selectedFolderId !== 'string' || this.selectedFolderId.length !== 0) {
          this.selectedFolderId = '';
        }
        if (typeof this.activeFolderId !== 'string' || this.activeFolderId.length !== 0) {
          this.activeFolderId = '';
        }
      }
    } catch (_) {
      // ignore
    }
  }

  private keywordSafe(): string {
    return typeof this.keyword === 'string' ? this.keyword : '';
  }

  private activeFolderIdSafe(): string {
    return typeof this.activeFolderId === 'string' ? this.activeFolderId : '';
  }

  aboutToAppear(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      this.noteRepo = new PreferencesNoteRepository(context);
      this.syncFolderIdFromRouteParams();
      this.loadData();
    } catch (_) {
      this.statusText = '初始化失败';
    }
  }

  onPageShow(): void {
    this.syncFolderIdFromRouteParams();
    this.loadData();
  }

  private getImportService(): NoteImportService | null {
    if (this.importService === null) {
      try {
        const context = getContext(this) as common.UIAbilityContext;
        this.importService = new NoteImportService(
          (progress: ImportProgress) => {
            this.importProgressStage = progress.stage;
            this.importProgressPercent = progress.percent;
            this.importProgressMessage = progress.message;
          },
          context.cacheDir
        );
      } catch (_) {
        this.importService = null;
      }
    }
    return this.importService;
  }

  private async loadData(): Promise<void> {
    if (!this.noteRepo) {
      this.statusText = '';
      return;
    }
    let stage: string = 'start';
    try {
      // Guard against accidental state pollution (ArkUI sometimes passes non-string values through router params / bindings).
      stage = 'sanitize_state';
      if (typeof this.keyword !== 'string') this.keyword = '';
      if (typeof this.activeFolderId !== 'string') this.activeFolderId = '';
      if (typeof this.selectedFolderId !== 'string') this.selectedFolderId = '';
      if (typeof this.statusText !== 'string') this.statusText = '';
      // activeFilter/sortMode are used in filtering/sorting; if polluted (e.g. undefined), it can filter everything out.
      if (this.activeFilter !== 'all' && this.activeFilter !== 'manual' && this.activeFilter !== 'web_clip' && this.activeFilter !== 'import') {
        this.activeFilter = 'all';
      }
      if (this.sortMode !== 'updated' && this.sortMode !== 'created' && this.sortMode !== 'title') {
        this.sortMode = 'updated';
      }

      try {
        stage = 'list_folders';
        this.folders = await this.noteRepo.listFolders();
      } catch (e) {
        this.folders = [];
        this.statusText = '';
      }

      let allNotes: Note[] = [];
      try {
        stage = 'list_notes';
        allNotes = await this.noteRepo.listNotes();
      } catch (e) {
        this.notes = [];
        this.displayNotes = [];
        this.statusText = '';
        return;
      }
      const safeNotes: Note[] = [];
      stage = 'normalize_notes';
      for (const raw of allNotes) {
        if (raw !== null && raw !== undefined) {
          const item = raw as Note;
          safeNotes.push(this.normalizeNote(item));
        }
      }
      this.notes = safeNotes;
      try {
        stage = 'apply_filter';
        this.applyFilter();
      } catch (e) {
        this.displayNotes = [];
        this.statusText = '';
        return;
      }

      stage = 'compose_status';
      this.statusText = '';
    } catch (e) {
      this.notes = [];
      this.displayNotes = [];
      // Keep silent for end users; we already render empty state.
      this.statusText = '';
    }
  }

  private normalizeNote(item: Note): Note {
    const now = Date.now();
    return {
      id: typeof item.id === 'string' && item.id.length > 0 ? item.id : `${now}_${Math.random().toString(36).substring(2, 8)}`,
      type: item.type === 'manual' || item.type === 'web_clip' || item.type === 'import' ? item.type : 'manual',
      title: typeof item.title === 'string' ? item.title : '',
      content: typeof item.content === 'string' ? item.content : '',
      contentPlain: typeof item.contentPlain === 'string' ? item.contentPlain : '',
      sourceUrl: typeof item.sourceUrl === 'string' ? item.sourceUrl : undefined,
      sourceTitle: typeof item.sourceTitle === 'string' ? item.sourceTitle : undefined,
      tags: Array.isArray(item.tags) ? item.tags : [],
      folderId: typeof item.folderId === 'string' ? item.folderId : undefined,
      isFavorite: item.isFavorite === true,
      importMeta: item.importMeta,
      readProgress: typeof item.readProgress === 'number' ? item.readProgress : 0,
      scrollPosition: typeof item.scrollPosition === 'string' ? item.scrollPosition : undefined,
      createdAt: typeof item.createdAt === 'number' ? item.createdAt : now,
      updatedAt: typeof item.updatedAt === 'number' ? item.updatedAt : now,
      deletedFlag: item.deletedFlag === true
    };
  }

  private get filteredNotes(): Note[] {
    // Always work on a copy to avoid reactive diff issues when `displayNotes` shares the same reference as `notes`.
    let result = (this.notes ?? []).slice();
    // Type filter
    if (this.activeFilter !== 'all') {
      result = result.filter((n: Note) => n.type === this.activeFilter);
    }
    // Folder filter
    let folderId = this.activeFolderIdSafe();
    if (folderId === NOTE_FOLDER_IDS.root) {
      folderId = '';
    }
    if (folderId.length > 0) {
      const allowed = this.resolveFolderWithChildren(folderId);
      result = result.filter((n: Note) => {
        const fid = typeof n.folderId === 'string' ? n.folderId : '';
        return allowed.has(fid);
      });
    }
    // Deleted filter
    result = result.filter((n: Note) => !n.deletedFlag);
    // Search
    const kw = this.keywordSafe().trim().toLowerCase();
    if (kw.length > 0) {
      result = result.filter((n: Note) => {
        const title = typeof n.title === 'string' ? n.title.toLowerCase() : '';
        const plain = typeof n.contentPlain === 'string' ? n.contentPlain.toLowerCase() : '';
        return title.includes(kw) || plain.includes(kw);
      });
    }
    // Sort
    result.sort((a: Note, b: Note) => this.compareBySortMode(a, b));
    return result;
  }

  private applyFilter(): void {
    let result: Note[] = (this.notes ?? []).slice();

    // Type filter
    const active = this.activeFilter;
    if (active !== 'all') {
      result = result.filter((n: Note) => n.type === active);
    }

    // Folder filter
    let folderId = this.activeFolderIdSafe();
    if (folderId === NOTE_FOLDER_IDS.root) folderId = '';
    if (folderId.length > 0) {
      const allowed = this.resolveFolderWithChildren(folderId);
      result = result.filter((n: Note) => {
        const fid = typeof n.folderId === 'string' ? n.folderId : '';
        return allowed.has(fid);
      });
    }

    // Deleted filter
    result = result.filter((n: Note) => n.deletedFlag !== true);

    // Search filter
    const kw = this.keywordSafe().trim().toLowerCase();
    if (kw.length > 0) {
      result = result.filter((n: Note) => {
        const title = typeof n.title === 'string' ? n.title.toLowerCase() : '';
        const plain = typeof n.contentPlain === 'string' ? n.contentPlain.toLowerCase() : '';
        return title.includes(kw) || plain.includes(kw);
      });
    }

    // Sort
    result.sort((a: Note, b: Note) => this.compareBySortMode(a, b));

    // Always assign a fresh array reference to trigger UI updates reliably.
    this.displayNotes = result.slice();
  }

  private compareBySortMode(a: Note, b: Note): number {
    if (this.sortMode === 'created') {
      return (b.createdAt ?? 0) - (a.createdAt ?? 0);
    }
    if (this.sortMode === 'title') {
      return (a.title || '').localeCompare(b.title || '', 'zh-Hans-CN');
    }
    return (b.updatedAt ?? 0) - (a.updatedAt ?? 0);
  }

  private sortLabel(): string {
    if (this.sortMode === 'created') return '排序：创建时间';
    if (this.sortMode === 'title') return '排序：标题';
    return '排序：更新时间';
  }

  private switchSortMode(): void {
    if (this.sortMode === 'updated') this.sortMode = 'created';
    else if (this.sortMode === 'created') this.sortMode = 'title';
    else this.sortMode = 'updated';
    this.applyFilter();
  }

  private resolveFolderWithChildren(folderId: string): Set<string> {
    const allowed = new Set<string>();
    const childrenMap = new Map<string, string[]>();
    for (const f of this.folders) {
      const parent = f.parentId ?? '';
      const list = childrenMap.get(parent) ?? [];
      list.push(f.id);
      childrenMap.set(parent, list);
    }
    const stack: string[] = [folderId];
    while (stack.length > 0) {
      const cur = stack.pop() as string;
      if (allowed.has(cur)) continue;
      allowed.add(cur);
      const kids = childrenMap.get(cur) ?? [];
      for (const k of kids) stack.push(k);
    }
    return allowed;
  }

  private folderNameById(id: string): string {
    for (const f of this.folders) {
      if (f.id === id) return f.name;
    }
    return '';
  }

  private isLocked(note: Note): boolean {
    return Array.isArray(note.tags) && note.tags.includes('__locked__');
  }

  private async toggleNoteLock(note: Note): Promise<void> {
    if (!this.noteRepo) return;
    const locked = this.isLocked(note);
    const nextTags = Array.isArray(note.tags) ? [...note.tags] : [];
    if (locked) {
      const filtered: string[] = [];
      for (const tag of nextTags) {
        if (tag !== '__locked__') filtered.push(tag);
      }
      note.tags = filtered;
    } else {
      nextTags.push('__locked__');
      note.tags = nextTags;
    }
    note.updatedAt = Date.now();
    try {
      await this.noteRepo.upsertNote(note);
      this.statusText = locked ? '已解锁' : '已锁定';
      this.applyFilter();
    } catch (_) {
      this.statusText = '操作失败';
    }
  }

  private noteTypeColor(type: string): string {
    if (type === 'import') return '#5F27CD';
    if (type === 'web_clip') return '#2ED573';
    return '#007DFF';
  }

  private noteTypeIcon(type: string): Resource {
    if (type === 'import') return $r('sys.symbol.doc_text');
    if (type === 'web_clip') return $r('sys.symbol.eye');
    return $r('sys.symbol.square_and_pencil');
  }

  private noteDateText(timestamp: number): string {
    if (typeof timestamp !== 'number' || timestamp <= 0) return '';
    const d = new Date(timestamp);
    const now = new Date();
    const pad = (n: number): string => n < 10 ? '0' + n : '' + n;
    if (d.toDateString() === now.toDateString()) {
      return '今天 ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
    }
    const yesterday = new Date(now);
    yesterday.setDate(yesterday.getDate() - 1);
    if (d.toDateString() === yesterday.toDateString()) {
      return '昨天 ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
    }
    return d.getFullYear() + '/' + (d.getMonth() + 1) + '/' + d.getDate();
  }

  private errorToMessage(err: Object): string {
    const e = err as ErrorLike;
    if (e.message !== undefined && e.message.length > 0) return e.message;
    if (e.code !== undefined) return `code=${e.code}`;
    if (e.name !== undefined && e.name.length > 0) return e.name;
    const asString = `${err}`;
    if (asString.length > 0 && asString !== '[object Object]') return asString;
    return '未知错误';
  }

  private async pickAndImport(fileType: 'txt' | 'epub'): Promise<void> {
    if (!this.noteRepo) return;
    const importService = this.getImportService();
    if (!importService) return;
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const results: string[] = await documentPicker.select();
      if (results.length === 0) return;
      this.showImportDialog = true;
      this.isImporting = true;

      const uri: string = results[0];
      const fileInfo = await importService.getFileInfo(uri);
      const detectedType = fileInfo.name.toLowerCase().endsWith('.epub') ? 'epub' : 'txt';

      let result: ImportResult;
      if (fileType === 'epub') {
        // EPUB needs local cache copy for zlib compatibility
        const localPath = this.copyUriToLocalCacheFile(uri, fileInfo.name);
        result = await importService.importEpub(localPath, fileInfo.name);
      } else {
        const localPath = this.copyUriToLocalCacheFile(uri, fileInfo.name);
        result = await importService.importTxt(localPath, fileInfo.name);
      }
      result.note.folderId = NOTE_FOLDER_IDS.study;
      await this.noteRepo.upsertNote(result.note);
      this.showImportDialog = false;
      this.isImporting = false;
      this.statusText = '导入完成';
      promptAction.showToast({ message: `${fileType.toUpperCase()} 导入成功` });
      await this.loadData();

      const detailParams: NoteDetailRouteParams = {
        noteId: result.note.id,
        isNew: 'false'
      };
      router.pushUrl({
        url: 'pages/NoteDetailPageSafe',
        params: detailParams
      }).catch(() => {
        promptAction.showToast({ message: '页面跳转失败' });
      });
    } catch (_) {
      this.showImportDialog = false;
      this.isImporting = false;
      const errText = this.errorToMessage(_ as Object);
      this.statusText = '导入失败: ' + errText;
      promptAction.showToast({ message: `导入失败: ${errText}` });
    }
  }

  private copyUriToLocalCacheFile(uri: string, fileName: string): string {
    const context = getContext(this) as common.UIAbilityContext;
    const importDir = `${context.cacheDir}/imports`;
    try {
      fs.mkdirSync(importDir);
    } catch (_) {
      // directory may already exist
    }
    const targetPath = `${importDir}/import_${Date.now()}_${Math.random().toString(36).substring(2, 8)}_${fileName}`;
    const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const dst = fs.openSync(targetPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      const bufSize = 64 * 1024;
      let readLen = -1;
      while (readLen !== 0) {
        const buf = new ArrayBuffer(bufSize);
        readLen = fs.readSync(src.fd, buf);
        if (readLen > 0) fs.writeSync(dst.fd, buf, { length: readLen });
      }
    } finally {
      fs.closeSync(src);
      fs.closeSync(dst);
    }
    return targetPath;
  }

  private navigateToNewNote(): void {
    const detailParams: NoteDetailRouteParams = { noteId: '', isNew: 'true' };
    router.pushUrl({
      url: 'pages/NoteDetailPageSafe',
      params: detailParams
    }).catch(() => {
      promptAction.showToast({ message: '页面跳转失败' });
    });
  }

  private navigateToNote(noteId: string): void {
    const detailParams: NoteDetailRouteParams = { noteId: noteId, isNew: 'false' };
    router.pushUrl({
      url: 'pages/NoteDetailPageSafe',
      params: detailParams
    }).catch(() => {
      promptAction.showToast({ message: '页面跳转失败' });
    });
  }

  private openFolderManager(mode: 'select' | 'move', noteId: string = ''): void {
    class FolderPageParams {
      mode: string = '';
      selectedFolderId: string = '';
      noteId: string = '';
    }
    const p = new FolderPageParams();
    p.mode = mode;
    p.selectedFolderId = this.activeFolderId;
    p.noteId = noteId;
    router.pushUrl({ url: 'pages/NoteFolderManagerPage', params: p }).catch(() => {
      promptAction.showToast({ message: '页面跳转失败' });
    });
  }

  private async confirmDeleteNote(): Promise<void> {
    if (!this.noteRepo) return;
    try {
      await this.noteRepo.deleteNote(this.deleteTargetNoteId);
      this.showDeleteConfirm = false;
      this.deleteTargetNoteId = '';
      await this.loadData();
      promptAction.showToast({ message: '已删除' });
    } catch (_) {
      promptAction.showToast({ message: '删除失败' });
    }
  }

  build() {
    Stack() {
      Column() {
        this.TopBar()
        this.SearchBar()
        this.SortBar()

        if ((this.displayNotes ?? []).length > 0) {
          this.NoteListView()
        } else {
          this.EmptyView()
        }

        this.FabButton()
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F5F7FA')

      if (this.showAddMenu) {
        this.AddMenuOverlay()
      }
      if (this.showDeleteConfirm) {
        this.DeleteConfirmOverlay()
      }
      if (this.showImportDialog) {
        this.ImportProgressOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  // ========== Top Bar ==========

  @Builder
  private TopBar() {
    Row() {
      Text('笔记')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor('#1A1A1A')
        .layoutWeight(1)

      Row({ space: 6 }) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(18)
            .fontColor(['#666666'])
        }
        .width(36)
        .height(36)
        .backgroundColor('#FFFFFF')
        .borderRadius(18)
        .onClick(() => {
          this.showSearchBar = !this.showSearchBar;
          if (!this.showSearchBar) this.keyword = '';
        })

        Button({ type: ButtonType.Normal }) {
          Text('···')
            .fontSize(18)
            .fontColor('#666666')
            .fontWeight(FontWeight.Bold)
        }
        .width(36)
        .height(36)
        .backgroundColor('#FFFFFF')
        .borderRadius(18)
        .onClick(() => {
          this.showTopActionMenu = !this.showTopActionMenu;
        })
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: 20, right: 16 })
    .backgroundColor('#FFFFFF')

    if (this.showTopActionMenu) {
      Row({ space: 8 }) {
        Button('全部')
          .height(30)
          .fontSize(12)
          .fontColor(this.activeFilter === 'all' ? '#FFFFFF' : '#666666')
          .backgroundColor(this.activeFilter === 'all' ? '#007DFF' : '#F0F0F0')
          .borderRadius(6)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.activeFilter = 'all';
            this.showTopActionMenu = false;
            this.applyFilter();
          })
        Button('笔记')
          .height(30)
          .fontSize(12)
          .fontColor(this.activeFilter === 'manual' ? '#FFFFFF' : '#666666')
          .backgroundColor(this.activeFilter === 'manual' ? '#007DFF' : '#F0F0F0')
          .borderRadius(6)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.activeFilter = 'manual';
            this.showTopActionMenu = false;
            this.applyFilter();
          })
        Button('摘录')
          .height(30)
          .fontSize(12)
          .fontColor(this.activeFilter === 'web_clip' ? '#FFFFFF' : '#666666')
          .backgroundColor(this.activeFilter === 'web_clip' ? '#007DFF' : '#F0F0F0')
          .borderRadius(6)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.activeFilter = 'web_clip';
            this.showTopActionMenu = false;
            this.applyFilter();
          })
        Button('文档')
          .height(30)
          .fontSize(12)
          .fontColor(this.activeFilter === 'import' ? '#FFFFFF' : '#666666')
          .backgroundColor(this.activeFilter === 'import' ? '#007DFF' : '#F0F0F0')
          .borderRadius(6)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.activeFilter = 'import';
            this.showTopActionMenu = false;
            this.applyFilter();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 8 })
      .backgroundColor('#FFFFFF')
    }
  }

  // ========== Search Bar ==========

  @Builder
  private SearchBar() {
    if (this.showSearchBar) {
      Row({ space: 8 }) {
        TextInput({ text: this.keywordSafe(), placeholder: '搜索标题、内容...' })
          .height(36)
          .layoutWeight(1)
          .backgroundColor('#F2F3F5')
          .borderRadius(8)
          .placeholderFont({ size: 14 })
          .placeholderColor('#CCCCCC')
          .fontSize(14)
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.keyword = value;
            this.applyFilter();
          })

        if (this.keywordSafe().length > 0) {
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(14)
              .fontColor(['#999999'])
          }
          .width(28)
          .height(28)
          .backgroundColor('#F0F0F0')
          .borderRadius(14)
          .onClick(() => {
            this.keyword = '';
            this.applyFilter();
          })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      .backgroundColor('#FFFFFF')
    }
  }

  // ========== Folder Bar ==========

  @Builder
  private FolderBar() {
    Scroll() {
      Row({ space: 6 }) {
        Text('全部')
          .fontSize(12)
          .fontColor(this.activeFolderIdSafe().length === 0 ? '#FFFFFF' : '#666666')
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .backgroundColor(this.activeFolderIdSafe().length === 0 ? '#5F27CD' : '#F0F0F0')
          .borderRadius(14)
          .onClick(() => {
            this.activeFolderId = '';
            this.selectedFolderId = '';
            this.applyFilter();
          })

        // folders 列表包含 root（“全部”），这里不重复展示
        ForEach(this.folders.filter((f: NoteFolder) => f.id !== NOTE_FOLDER_IDS.root), (folder: NoteFolder) => {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.folder'))
              .fontSize(11)
              .fontColor([this.activeFolderId === folder.id ? '#FFFFFF' : '#5F27CD'])
            Text(folder.name)
              .fontSize(12)
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.activeFolderId === folder.id ? '#5F27CD' : '#F5F0FA')
          .borderRadius(14)
          .onClick(() => {
            this.activeFolderId = this.activeFolderId === folder.id ? '' : folder.id;
            this.selectedFolderId = this.activeFolderId;
            this.applyFilter();
          })
        })
      }
      .padding({ left: 16, right: 16, top: 2, bottom: 6 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .height(34)
    .backgroundColor('#FFFFFF')
  }

  // ========== Sort Bar ==========

  @Builder
  private SortBar() {
    Row() {
      Row({ space: 4 }) {
        Text(this.sortLabel())
          .fontSize(12)
          .fontColor('#999999')
      }
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .backgroundColor('#F0F0F0')
      .borderRadius(6)
      .onClick(() => {
        this.switchSortMode();
      })

      Blank()
        .layoutWeight(1)

      Row({ space: 8 }) {
        Text(((this.displayNotes ?? []).length) + ' 条笔记')
          .fontSize(12)
          .fontColor('#BBBBBB')

        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.folder'))
            .fontSize(12)
            .fontColor(['#5F27CD'])
          Text('管理')
            .fontSize(12)
            .fontColor('#5F27CD')
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .backgroundColor('#F5F0FA')
        .borderRadius(6)
        .onClick(() => {
          this.openFolderManager('select');
        })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 4 })
    .backgroundColor('#FFFFFF')
  }

  // ========== Note List ==========

  @Builder
  private NoteListView() {
    List() {
      ForEach(this.displayNotes ?? [], (note: Note) => {
        ListItem() {
          this.NoteCard(note)
        }
      }, (item: Note) => item.id + '_' + item.updatedAt)
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 12, right: 12, top: 4, bottom: 80 })
  }

  // ========== Note Card ==========

  @Builder
  private NoteCard(note: Note) {
    Column() {
      Row() {
        SymbolGlyph(this.noteTypeIcon(note.type))
          .fontSize(16)
          .fontColor([this.noteTypeColor(note.type)])

        Text(typeof note.title === 'string' && note.title.length > 0 ? note.title : '无标题')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1A1A1A')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 8 })

        if (this.isLocked(note)) {
          SymbolGlyph($r('sys.symbol.lock'))
            .fontSize(12)
            .fontColor(['#B26A00'])
            .margin({ left: 4 })
        }
        if (note.isFavorite) {
          SymbolGlyph($r('sys.symbol.star_fill'))
            .fontSize(12)
            .fontColor(['#FFC107'])
            .margin({ left: 4 })
        }
      }
      .width('100%')

      if (typeof note.contentPlain === 'string' && note.contentPlain.trim().length > 0) {
        Text(note.contentPlain)
          .fontSize(13)
          .fontColor('#666666')
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(18)
          .margin({ top: 6 })
      }

      Row() {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.clock'))
            .fontSize(11)
            .fontColor(['#AAAAAA'])
          Text(this.noteDateText(note.updatedAt))
            .fontSize(11)
            .fontColor('#AAAAAA')
        }

        if (typeof note.folderId === 'string' && note.folderId.length > 0) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.folder'))
              .fontSize(11)
              .fontColor(['#AAAAAA'])
              .margin({ left: 8 })
            Text(this.folderNameById(note.folderId))
              .fontSize(11)
              .fontColor('#AAAAAA')
          }
        }

        if (Array.isArray(note.tags) && note.tags.length > 0) {
          Row({ space: 2 }) {
            Text(Array.isArray(note.tags) ? note.tags[0] : '')
              .fontSize(10)
              .fontColor('#007DFF')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor('#E8F4FF')
              .borderRadius(8)
              .margin({ left: 8 })
            if (note.tags.length > 1) {
              Text('+' + (note.tags.length - 1))
                .fontSize(10)
                .fontColor('#999999')
            }
          }
        }

        Blank()
          .layoutWeight(1)

        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(13)
            .fontColor(['#CCCCCC'])
        }
        .width(28)
        .height(28)
        .backgroundColor('transparent')
        .borderRadius(14)
        .onClick(() => {
          this.deleteTargetNoteId = note.id;
          this.showDeleteConfirm = true;
        })
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .padding(14)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .shadow({
      radius: 4,
      color: 'rgba(0, 0, 0, 0.06)',
      offsetX: 0,
      offsetY: 2
    })
    .margin({ bottom: 8 })
    .onClick(() => {
      this.navigateToNote(note.id);
    })
  }

  // ========== Empty View ==========

  @Builder
  private EmptyView() {
    Column() {
      SymbolGlyph($r('sys.symbol.doc_text'))
        .fontSize(48)
        .fontColor(['#E0E0E0'])
      Text(this.keywordSafe().trim().length > 0 ? '没有找到匹配的笔记' : '还没有笔记')
        .fontSize(15)
        .fontColor('#999999')
        .margin({ top: 16 })
      if (this.keywordSafe().trim().length === 0) {
        Text('点击右下角 + 创建第一条笔记')
          .fontSize(13)
          .fontColor('#CCCCCC')
          .margin({ top: 8 })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ========== FAB ==========

  @Builder
  private FabButton() {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize(24)
        .fontColor(['#FFFFFF'])
    }
    .width(56)
    .height(56)
    .backgroundColor('#007DFF')
    .shadow({
      radius: 12,
      color: 'rgba(0, 125, 255, 0.4)',
      offsetX: 0,
      offsetY: 4
    })
    .position({ bottom: 28, right: 20 })
    .onClick(() => {
      this.showAddMenu = !this.showAddMenu;
    })
  }

  // ========== Add Menu Overlay ==========

  @Builder
  private AddMenuOverlay() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.25)')
        .onClick(() => {
          this.showAddMenu = false;
        })

      Column() {
        Row() {
          this.AddMenuItem($r('sys.symbol.square_and_pencil'), '新建笔记', '#007DFF', () => {
            this.showAddMenu = false;
            this.navigateToNewNote();
          })
          this.AddMenuItem($r('sys.symbol.doc_text'), '导入 TXT', '#5F27CD', () => {
            this.showAddMenu = false;
            this.pickAndImport('txt');
          })
          this.AddMenuItem($r('sys.symbol.doc_text'), '导入 EPUB', '#2ED573', () => {
            this.showAddMenu = false;
            this.pickAndImport('epub');
          })
        }
        .width('100%')
        .padding(20)
        .justifyContent(FlexAlign.SpaceAround)
      }
      .width('100%')
      .backgroundColor('#FFFFFF')
      .borderRadius({ topLeft: 20, topRight: 20 })
      .position({ bottom: 0 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private AddMenuItem(icon: Resource, label: string, color: string, action: () => void) {
    Column({ space: 8 }) {
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph(icon)
          .fontSize(24)
          .fontColor([color])
      }
      .width(52)
      .height(52)
      .backgroundColor(color + '15')
      .borderRadius(26)

      Text(label)
        .fontSize(12)
        .fontColor('#333333')
    }
    .alignItems(HorizontalAlign.Center)
    .onClick(() => { action(); })
  }

  // ========== Delete Confirm Overlay ==========

  @Builder
  private DeleteConfirmOverlay() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.25)')

      Column({ space: 16 }) {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(36)
          .fontColor(['#FF4757'])

        Text('确定删除这条笔记吗？')
          .fontSize(16)
          .fontColor('#1A1A1A')

        Text('删除后可通过同步恢复')
          .fontSize(13)
          .fontColor('#999999')

        Row({ space: 12 }) {
          Button('取消')
            .fontSize(14)
            .fontColor('#666666')
            .height(40)
            .layoutWeight(1)
            .backgroundColor('#F0F0F0')
            .borderRadius(8)
            .onClick(() => {
              this.showDeleteConfirm = false;
            })

          Button('删除')
            .fontSize(14)
            .fontColor('#FFFFFF')
            .height(40)
            .layoutWeight(1)
            .backgroundColor('#FF4757')
            .borderRadius(8)
            .onClick(() => {
              this.confirmDeleteNote();
            })
        }
        .width('100%')
      }
      .width(280)
      .padding(24)
      .backgroundColor('#FFFFFF')
      .borderRadius(20)
      .alignItems(HorizontalAlign.Center)
      .shadow({
        radius: 16,
        color: 'rgba(0, 0, 0, 0.1)',
        offsetX: 0,
        offsetY: 4
      })
    }
    .width('100%')
    .height('100%')
  }

  // ========== Import Progress Overlay ==========

  @Builder
  private ImportProgressOverlay() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.3)')

      Column({ space: 16 }) {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(36)
          .fontColor(['#007DFF'])

        Text(this.importProgressMessage)
          .fontSize(15)
          .fontColor('#1A1A1A')

        if (this.importProgressPercent > 0) {
          Progress({ value: this.importProgressPercent, total: 100, type: ProgressType.Linear })
            .width(200)
            .height(4)
            .color('#007DFF')
            .backgroundColor('#F0F0F0')
        }

        Text(this.importProgressPercent + '%')
          .fontSize(12)
          .fontColor('#999999')
      }
      .width(260)
      .padding(32)
      .backgroundColor('#FFFFFF')
      .borderRadius(20)
      .alignItems(HorizontalAlign.Center)
      .shadow({
        radius: 16,
        color: 'rgba(0, 0, 0, 0.1)',
        offsetX: 0,
        offsetY: 4
      })
    }
    .width('100%')
    .height('100%')
  }
}
