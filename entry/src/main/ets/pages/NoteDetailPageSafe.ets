import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { Note, NoteFolder, Chapter, NoteType } from '../model/Note';
import { NoteRepository } from '../repository/NoteRepository';
import { NOTE_FOLDER_IDS, PreferencesNoteRepository } from '../repository/PreferencesNoteRepository';

interface MarkdownBlock {
  type: string;
  content: string;
  level: number;
}

interface ToolbarItem {
  label: string;
  insertBefore: string;
  insertAfter: string;
  newLineBefore: boolean;
  newLineAfter: boolean;
}

interface DialogResult {
  index: number;
}

interface BgModeOption {
  key: string;
  label: string;
  bg: string;
  text: string;
}

interface FontSizeOption {
  value: number;
  label: string;
}

interface LineHeightOption {
  value: number;
  label: string;
}

const AUTO_SAVE_DELAY: number = 3000;

const TOOLBAR_ITEMS: ToolbarItem[] = [
  { label: 'H1', insertBefore: '# ', insertAfter: '', newLineBefore: true, newLineAfter: true },
  { label: 'H2', insertBefore: '## ', insertAfter: '', newLineBefore: true, newLineAfter: true },
  { label: 'H3', insertBefore: '### ', insertAfter: '', newLineBefore: true, newLineAfter: true },
  { label: 'B', insertBefore: '**', insertAfter: '**', newLineBefore: false, newLineAfter: false },
  { label: 'I', insertBefore: '*', insertAfter: '*', newLineBefore: false, newLineAfter: false },
  { label: '`', insertBefore: '`', insertAfter: '`', newLineBefore: false, newLineAfter: false },
  { label: '>', insertBefore: '> ', insertAfter: '', newLineBefore: true, newLineAfter: true },
  { label: '-', insertBefore: '- ', insertAfter: '', newLineBefore: true, newLineAfter: false },
  { label: '1.', insertBefore: '1. ', insertAfter: '', newLineBefore: true, newLineAfter: false },
  { label: '---', insertBefore: '\n---\n', insertAfter: '', newLineBefore: false, newLineAfter: false }
];

const BG_MODES: BgModeOption[] = [
  { key: 'white', label: '白', bg: '#FFFFFF', text: '#1A1A1A' },
  { key: 'paper', label: '纸', bg: '#F5F0E8', text: '#1A1A1A' },
  { key: 'gray', label: '灰', bg: '#F0F0F0', text: '#1A1A1A' },
  { key: 'dark', label: '暗', bg: '#1A1A2E', text: '#E0E0E0' }
];

const FONT_SIZES: FontSizeOption[] = [
  { value: 14, label: '小' },
  { value: 16, label: '中' },
  { value: 18, label: '大' },
  { value: 20, label: '超大' }
];

const LINE_HEIGHTS: LineHeightOption[] = [
  { value: 20, label: '紧凑' },
  { value: 24, label: '舒适' },
  { value: 30, label: '宽松' },
  { value: 36, label: '超宽' }
];

@Entry
@Component
struct NoteDetailPageSafe {
  @State note: Note | null = null;
  @State isLoading: boolean = true;
  @State errorText: string = '';
  @State isNew: boolean = false;
  @State editTitle: string = '';
  @State editContent: string = '';
  @State isEditing: boolean = false;
  @State readingFontSize: number = 16;
  @State readingLineHeight: number = 24;
  @State saveStatusText: string = '';
  @State lastSavedTimeText: string = '';
  @State showActionMenu: boolean = false;
  @State showReadingSettings: boolean = false;
  @State showChapterNav: boolean = false;
  @State bgMode: string = 'white';
  @State scrollOffset: number = 0;
  @State contentHeight: number = 0;
  @State viewportHeight: number = 0;
  @State folders: NoteFolder[] = [];
  @State showFolderPicker: boolean = false;
  @State editFolderId: string = '';
  @State editTags: string[] = [];
  @State newTagInput: string = '';
  @State showTagInput: boolean = false;
  @State showPreview: boolean = false;
  @State showEditChapterOutline: boolean = false;
  private noteRepo: NoteRepository | null = null;
  private noteId: string = '';
  private autoSaveTimer: number | null = null;
  private saveStatusClearTimer: number | null = null;
  private isDeletingOrDeleted: boolean = false;
  private isHandlingBack: boolean = false;
  /** 跳过首次 onPageShow，避免与 aboutToAppear 重复 load；之后用于检测路由参数变化（页面复用时）。 */
  private pageShowCount: number = 0;
  private headingPositions: Record<string, number> = {};
  private isCurrentChapter(index: number): boolean {
    return !this.isEditing && index === this.currentChapterIndex;
  }

  /** router 传参可能是 string / boolean；自定义 class 作 params 时可能丢字段，列表页已改为 Record。 */
  private parseRouteParams(): void {
    const params = router.getParams() as Record<string, string | boolean | number | undefined>;
    const rawId = params?.['noteId'];
    this.noteId = typeof rawId === 'string' ? rawId.trim() : '';
    const rawNew = params?.['isNew'];
    this.isNew = rawNew === true || rawNew === 'true';
  }

  aboutToAppear(): void {
    try {
      this.parseRouteParams();
      const context = getContext(this) as common.UIAbilityContext;
      this.noteRepo = new PreferencesNoteRepository(context);
      this.loadFolders();
      this.loadNote();
    } catch (_) {
      this.isLoading = false;
      this.errorText = '初始化失败';
    }
  }

  onPageShow(): void {
    if (this.isDeletingOrDeleted) {
      return;
    }
    this.pageShowCount++;
    if (this.pageShowCount <= 1) {
      return;
    }
    const prevId = this.noteId;
    const prevNew = this.isNew;
    this.parseRouteParams();
    if (this.noteId !== prevId || this.isNew !== prevNew) {
      void this.loadFolders();
      void this.loadNote();
    }
  }

  onPageHide(): void {
    if (this.isDeletingOrDeleted) return;
    void this.flushAutoSave();
  }

  onBackPress(): boolean {
    if (this.isDeletingOrDeleted) return false;
    // Intercept system back to avoid read-after-write race across pages.
    if (this.isHandlingBack) return true;
    this.isHandlingBack = true;
    void this.flushAutoSave().finally(() => {
      router.back();
      this.isHandlingBack = false;
    });
    return true;
  }

  // ========== Data Loading ==========

  private async loadNote(): Promise<void> {
    if (this.isNew) {
      const now = Date.now();
      this.note = {
        id: `note_new_${now}`,
        type: 'manual',
        title: '',
        content: '',
        contentPlain: '',
        tags: [],
        folderId: NOTE_FOLDER_IDS.personal,
        isFavorite: false,
        readProgress: 0,
        createdAt: now,
        updatedAt: now,
        deletedFlag: false
      };
      this.editTitle = '';
      this.editContent = '';
      this.editTags = [];
      this.editFolderId = NOTE_FOLDER_IDS.personal ?? '';
      this.isEditing = true;
      this.errorText = '';
      this.isLoading = false;
      return;
    }
    if (!this.noteRepo || this.noteId.length === 0) {
      this.isLoading = false;
      this.errorText = '参数无效';
      return;
    }
    this.isLoading = true;
    try {
      const item = await this.noteRepo.getNoteById(this.noteId);
      this.note = item;
      if (!item) {
        this.errorText = '笔记不存在';
      } else {
        this.editTitle = typeof item.title === 'string' ? item.title : '';
        this.editContent = typeof item.content === 'string' ? item.content : '';
        this.editFolderId = item.folderId ?? '';
        this.editTags = Array.isArray(item.tags) ? item.tags.slice() : [];
        this.isEditing = item.type !== 'import' && !this.isLockedNote(item);
      }
    } catch (_) {
      this.errorText = '加载失败';
      this.note = null;
    }
    this.isLoading = false;
  }

  private async loadFolders(): Promise<void> {
    if (!this.noteRepo) return;
    try {
      this.folders = await this.noteRepo.listFolders();
    } catch (_) {
      this.folders = [];
    }
  }

  // ========== Computed Values ==========

  private get readingProgress(): number {
    if (this.contentHeight <= 0 || this.viewportHeight <= 0) return 0;
    const maxScroll = Math.max(this.contentHeight - this.viewportHeight, 1);
    return Math.min(Math.round((this.scrollOffset / maxScroll) * 100), 100);
  }

  private get progressPercent(): number {
    const p = this.readingProgress;
    return p > 0 && p < 100 ? p : 0;
  }

  private get currentBgMode(): BgModeOption {
    for (const m of BG_MODES) {
      if (m.key === this.bgMode) return m;
    }
    return BG_MODES[0];
  }

  private get bgColor(): string {
    return this.currentBgMode.bg;
  }

  private get textColor(): string {
    return this.currentBgMode.text;
  }

  private get chapters(): Chapter[] {
    if (!this.note) return [];
    const meta = this.note.importMeta;
    if (meta && meta.chapters.length > 0) return meta.chapters;
    return this.extractChaptersFromBlocks(this.parsedBlocks);
  }

  private get parsedBlocks(): MarkdownBlock[] {
    return this.parseMarkdown(this.note?.content ?? '');
  }

  private get editPreviewBlocks(): MarkdownBlock[] {
    return this.parseMarkdown(this.editContent);
  }

  private get editChapters(): Chapter[] {
    return this.extractChaptersFromBlocks(this.parseMarkdown(this.editContent));
  }

  private get hasChapters(): boolean {
    return this.chapters.length > 1;
  }

  private get currentChapterIndex(): number {
    const n: number = this.chapters.length;
    for (let i = n - 1; i >= 0; i--) {
      const pos = this.headingPositions['ch_' + (i + 1)];
      if (pos !== undefined && pos <= this.scrollOffset + 80) {
        return i;
      }
    }
    return -1;
  }

  // ========== Auto Save ==========

  private async persistCurrentNote(showToast: boolean): Promise<boolean> {
    if (!this.noteRepo || !this.note) {
      if (showToast) promptAction.showToast({ message: '保存失败' });
      this.setSaveStatus('保存失败', false);
      return false;
    }
    const now = Date.now();
    const title = this.editTitle.trim().length > 0 ? this.editTitle.trim() : '无标题';
    const content = this.editContent;
    const plain = content.replace(/[#*`>\-\[\]()!]/g, '').substring(0, 300);
    const toSave: Note = {
      id: this.note.id,
      type: this.note.type ?? 'manual',
      title: title,
      content: content,
      contentPlain: plain,
      sourceUrl: this.note.sourceUrl,
      sourceTitle: this.note.sourceTitle,
      tags: this.editTags.slice(),
      folderId: this.editFolderId.length > 0 ? this.editFolderId : undefined,
      isFavorite: this.note.isFavorite === true,
      importMeta: this.note.importMeta,
      readProgress: typeof this.note.readProgress === 'number' ? this.note.readProgress : 0,
      scrollPosition: this.note.scrollPosition,
      createdAt: typeof this.note.createdAt === 'number' ? this.note.createdAt : now,
      updatedAt: now,
      deletedFlag: this.note.deletedFlag === true
    };
    try {
      await this.noteRepo.upsertNote(toSave);
      // Read-back verification to catch flush races / silent storage failures.
      try {
        const reloaded = await this.noteRepo.getNoteById(toSave.id);
        if (!reloaded || reloaded.updatedAt < toSave.updatedAt) {
          throw new Error('readback mismatch');
        }
      } catch (_) {
        this.setSaveStatus('保存失败', false);
        if (showToast) promptAction.showToast({ message: '保存失败' });
        return false;
      }
      this.note = toSave;
      this.noteId = toSave.id;
      this.isNew = false;
      this.setSaveStatus('已保存', true, now);
      if (showToast) promptAction.showToast({ message: '已保存' });
      return true;
    } catch (_) {
      this.setSaveStatus('保存失败', false);
      if (showToast) promptAction.showToast({ message: '保存失败' });
      return false;
    }
  }

  private scheduleAutoSave(): void {
    if (this.isDeletingOrDeleted || !this.isEditing) return;
    if (this.autoSaveTimer !== null) {
      clearTimeout(this.autoSaveTimer);
      this.autoSaveTimer = null;
    }
    this.autoSaveTimer = setTimeout(() => {
      this.autoSaveTimer = null;
      this.persistCurrentNote(false);
    }, AUTO_SAVE_DELAY);
  }

  /**
   * Clears debounce timer and persists current editor state.
   * Always runs persist when possible — previously only persisted when a timer was pending,
   * so return /「保存」 could skip writes after autosave had already fired.
   */
  private async flushAutoSave(): Promise<void> {
    if (this.isDeletingOrDeleted) {
      if (this.autoSaveTimer !== null) {
        clearTimeout(this.autoSaveTimer);
        this.autoSaveTimer = null;
      }
      return;
    }
    if (this.autoSaveTimer !== null) {
      clearTimeout(this.autoSaveTimer);
      this.autoSaveTimer = null;
    }
    await this.persistCurrentNote(false);
  }

  private onEditContentChange(): void {
    this.setSaveStatus('编辑中', false);
    this.scheduleAutoSave();
  }

  // ========== Save Status ==========

  private setSaveStatus(text: string, autoClear: boolean, timestamp?: number): void {
    this.saveStatusText = text;
    if (text === '已保存' && timestamp !== undefined) {
      this.lastSavedTimeText = this.formatTime(timestamp);
    }
    if (this.saveStatusClearTimer !== null) {
      clearTimeout(this.saveStatusClearTimer);
      this.saveStatusClearTimer = null;
    }
    if (autoClear) {
      this.saveStatusClearTimer = setTimeout(() => {
        this.saveStatusText = '';
        this.lastSavedTimeText = '';
        this.saveStatusClearTimer = null;
      }, 2000);
    }
  }

  // ========== Lock / Delete ==========

  private isLockedNote(note: Note): boolean {
    return Array.isArray(note.tags) && note.tags.includes('__locked__');
  }

  private confirmDelete(): void {
    if (this.isNew || !this.note || !this.noteRepo) return;
    promptAction.showDialog({
      title: '删除笔记',
      message: `确定删除「${this.note.title || '无标题'}」吗？`,
      buttons: [
        { text: '取消', color: '#999999' },
        { text: '删除', color: '#FF4757' }
      ]
    }).then(async (result: DialogResult) => {
      if (result.index !== 1 || !this.note || !this.noteRepo) return;
      try {
        this.isDeletingOrDeleted = true;
        if (this.autoSaveTimer !== null) {
          clearTimeout(this.autoSaveTimer);
          this.autoSaveTimer = null;
        }
        await this.noteRepo.deleteNote(this.note.id);
        this.note = null;
        promptAction.showToast({ message: '已删除' });
        router.back();
      } catch (_) {
        this.isDeletingOrDeleted = false;
        promptAction.showToast({ message: '删除失败' });
      }
    });
  }

  // ========== Copy ==========

  private copyContent(): void {
    if (this.editContent.length === 0) {
      promptAction.showToast({ message: '暂无可复制内容' });
      return;
    }
    try {
      const systemPasteboard = pasteboard.getSystemPasteboard();
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.editContent);
      systemPasteboard.setData(data).then(() => {
        promptAction.showToast({ message: '已复制正文' });
      }).catch(() => {
        promptAction.showToast({ message: '复制失败' });
      });
    } catch (_) {
      promptAction.showToast({ message: '复制失败' });
    }
  }

  private copyTitle(): void {
    const title = this.editTitle.trim();
    if (title.length === 0) {
      promptAction.showToast({ message: '暂无可复制标题' });
      return;
    }
    try {
      const systemPasteboard = pasteboard.getSystemPasteboard();
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, title);
      systemPasteboard.setData(data).then(() => {
        promptAction.showToast({ message: '已复制标题' });
      }).catch(() => {
        promptAction.showToast({ message: '复制失败' });
      });
    } catch (_) {
      promptAction.showToast({ message: '复制失败' });
    }
  }

  private copyTitleAndContent(): void {
    const title = this.editTitle.trim().length > 0 ? this.editTitle.trim() : '无标题';
    const content = this.editContent;
    if (content.length === 0) {
      this.copyTitle();
      return;
    }
    try {
      const systemPasteboard = pasteboard.getSystemPasteboard();
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, `${title}\n\n${content}`);
      systemPasteboard.setData(data).then(() => {
        promptAction.showToast({ message: '已复制标题和正文' });
      }).catch(() => {
        promptAction.showToast({ message: '复制失败' });
      });
    } catch (_) {
      promptAction.showToast({ message: '复制失败' });
    }
  }

  // ========== Stats ==========

  private countCharacters(text: string): number {
    return typeof text === 'string' ? text.length : 0;
  }

  private estimatedReadMinutes(text: string): number {
    const chars = this.countCharacters(text);
    return chars > 0 ? Math.max(1, Math.ceil(chars / 350)) : 0;
  }

  // ========== Tag Management ==========

  private addTag(): void {
    const tag = this.newTagInput.trim();
    if (tag.length === 0) return;
    if (this.editTags.indexOf(tag) < 0) {
      this.editTags.push(tag);
      this.editTags = this.editTags.slice();
      this.onEditContentChange();
    }
    this.newTagInput = '';
  }

  private removeTag(index: number): void {
    this.editTags.splice(index, 1);
    this.editTags = this.editTags.slice();
    this.onEditContentChange();
  }

  // ========== Markdown Parser ==========

  private parseMarkdown(text: string): MarkdownBlock[] {
    if (text.length === 0) {
      return [{ type: 'paragraph', content: '', level: 0 }];
    }
    const lines: string[] = text.split('\n');
    const blocks: MarkdownBlock[] = [];
    let inCodeBlock: boolean = false;
    let codeBuffer: string[] = [];
    let listIndex: number = 0;

    for (let i = 0; i < lines.length; i++) {
      const raw: string = lines[i];
      const trimmed: string = raw.trim();

      if (trimmed.startsWith('```')) {
        if (inCodeBlock) {
          blocks.push({ type: 'codeblock', content: codeBuffer.join('\n'), level: 0 });
          codeBuffer = [];
          inCodeBlock = false;
        } else {
          inCodeBlock = true;
        }
        continue;
      }
      if (inCodeBlock) {
        codeBuffer.push(raw);
        continue;
      }

      if (trimmed.length === 0) {
        blocks.push({ type: 'empty', content: '', level: 0 });
        listIndex = 0;
        continue;
      }

      if (trimmed.startsWith('#') && trimmed.length > 1 && trimmed[1] === ' ') {
        let level: number = 1;
        let contentStart: number = 2;
        for (let j = 1; j < 7 && j < trimmed.length; j++) {
          if (trimmed[j] === '#') {
            level++;
            contentStart = j + 2;
          } else {
            break;
          }
        }
        blocks.push({ type: 'h' + level, content: this.inlineFormat(trimmed.substring(contentStart).trim()), level: 0 });
        listIndex = 0;
        continue;
      }

      if (/^[-*_]{3,}$/.test(trimmed)) {
        blocks.push({ type: 'hr', content: '', level: 0 });
        listIndex = 0;
        continue;
      }

      if (trimmed.startsWith('> ')) {
        blocks.push({ type: 'blockquote', content: this.inlineFormat(trimmed.substring(2)), level: 0 });
        listIndex = 0;
        continue;
      }

      if (trimmed.startsWith('- ') || trimmed.startsWith('* ') || trimmed.startsWith('+ ')) {
        blocks.push({ type: 'unordered-list', content: this.inlineFormat(trimmed.substring(2)), level: 0 });
        listIndex = 0;
        continue;
      }

      const dotIdx: number = trimmed.indexOf('. ');
      if (dotIdx > 0 && /^\d+$/.test(trimmed.substring(0, dotIdx))) {
        listIndex++;
        blocks.push({ type: 'ordered-list', content: this.inlineFormat(trimmed.substring(dotIdx + 2)), level: listIndex });
        continue;
      }

      blocks.push({ type: 'paragraph', content: this.inlineFormat(trimmed), level: 0 });
      listIndex = 0;
    }

    if (inCodeBlock && codeBuffer.length > 0) {
      blocks.push({ type: 'codeblock', content: codeBuffer.join('\n'), level: 0 });
    }

    return this.mergeParagraphs(blocks);
  }

  private inlineFormat(text: string): string {
    let result: string = text;
    result = result.replace(/\*\*(.+?)\*\*/g, '$1');
    result = result.replace(/\*(.+?)\*/g, '$1');
    result = result.replace(/`(.+?)`/g, '$1');
    result = result.replace(/\[(.+?)\]\(.+?\)/g, '$1');
    result = result.replace(/!\[(.+?)\]\(.+?\)/g, '$1');
    return result;
  }

  private mergeParagraphs(blocks: MarkdownBlock[]): MarkdownBlock[] {
    const result: MarkdownBlock[] = [];
    for (const block of blocks) {
      if (block.type === 'paragraph' && result.length > 0) {
        const last = result[result.length - 1];
        if (last.type === 'paragraph') {
          last.content += ' ' + block.content;
          continue;
        }
      }
      result.push({ type: block.type, content: block.content, level: block.level });
    }
    return result;
  }

  private extractChaptersFromBlocks(blocks: MarkdownBlock[]): Chapter[] {
    const chapters: Chapter[] = [];
    let chIndex: number = 0;
    for (const block of blocks) {
      if (block.type === 'h1' || block.type === 'h2' || block.type === 'h3') {
        chIndex++;
        chapters.push({
          title: block.content,
          anchor: 'ch_' + chIndex,
          level: parseInt(block.type.substring(1))
        });
      }
    }
    return chapters;
  }

  // ========== Save Reading Progress ==========

  private async saveProgress(): Promise<void> {
    if (!this.note || !this.noteRepo) return;
    const p = this.readingProgress;
    if (p !== this.note.readProgress) {
      this.note.readProgress = p;
      try {
        await this.noteRepo.upsertNote(this.note);
      } catch (_) {
        // silently fail
      }
    }
  }

  // ========== Formatting ==========

  private formatDate(timestamp: number): string {
    if (typeof timestamp !== 'number' || timestamp <= 0) return '';
    const d = new Date(timestamp);
    const y = d.getFullYear();
    const m = `${d.getMonth() + 1}`.padStart(2, '0');
    const day = `${d.getDate()}`.padStart(2, '0');
    return `${y}-${m}-${day}`;
  }

  private formatTime(timestamp: number): string {
    if (typeof timestamp !== 'number' || timestamp <= 0) return '';
    const d = new Date(timestamp);
    const hh = `${d.getHours()}`.padStart(2, '0');
    const mm = `${d.getMinutes()}`.padStart(2, '0');
    return `${hh}:${mm}`;
  }

  private noteTypeLabel(type: string): string {
    if (type === 'import') return '文档';
    if (type === 'web_clip') return '摘录';
    return '笔记';
  }

  // ========== BUILD ==========

  build() {
    Stack() {
      Column() {
        this.TopBar()

        if (this.isLoading) {
          this.LoadingView()
        } else if (!this.note && !this.isNew) {
          this.ErrorView()
        } else if (this.isEditing) {
          this.EditorView()
        } else {
          this.ReaderView()
        }

        if (!this.isEditing && this.showReadingSettings) {
          this.ReadingSettingsBar()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F5F7FA')

      if (this.showActionMenu) {
        this.ActionMenuOverlay()
      }
      if (this.showChapterNav && this.chapters.length > 0) {
        this.ChapterNavPanel()
      }
    }
    .width('100%')
    .height('100%')
  }

  // ========== Top Bar ==========

  @Builder
  private TopBar() {
    Row() {
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(20)
          .fontColor(['#1A1A1A'])
      }
      .width(40)
      .height(40)
      .backgroundColor('#FFFFFF')
      .borderRadius(20)
      .onClick(async () => {
        await this.flushAutoSave();
        router.back();
      })

      Column() {
        if (this.isEditing) {
          TextInput({ text: this.editTitle, placeholder: '输入标题...' })
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1A1A1A')
            .placeholderFont({ size: 16 })
            .placeholderColor('#CCCCCC')
            .height(36)
            .backgroundColor('#FFFFFF')
            .onChange((value: string) => {
              this.editTitle = value;
              this.onEditContentChange();
            })
        } else {
          Text(this.note?.title ?? '笔记')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1A1A1A')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 4, right: 4 })

      // Save status
      if (this.saveStatusText.length > 0) {
        Text(this.lastSavedTimeText.length > 0
          ? `${this.saveStatusText} ${this.lastSavedTimeText}`
          : this.saveStatusText)
          .fontSize(11)
          .fontColor(this.saveStatusText === '已保存' ? '#2ED573' : this.saveStatusText === '编辑中' ? '#FFC107' : '#FF4757')
          .margin({ right: 4 })
      }

      // Edit/View toggle
      if (this.note && this.note.type !== 'import') {
        if (this.isEditing) {
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.eye'))
              .fontSize(18)
              .fontColor(['#007DFF'])
          }
          .width(40)
          .height(40)
          .backgroundColor('#E8F4FF')
          .borderRadius(20)
          .onClick(async () => {
            await this.flushAutoSave();
            this.isEditing = false;
          })
        } else {
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.square_and_pencil'))
              .fontSize(18)
              .fontColor(['#666666'])
          }
          .width(40)
          .height(40)
          .backgroundColor('#FFFFFF')
          .borderRadius(20)
          .onClick(() => {
            this.isEditing = true;
          })
        }
      }

      // Chapter nav toggle
      if (this.hasChapters) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.list_bullet'))
            .fontSize(18)
            .fontColor([this.showChapterNav ? '#007DFF' : '#666666'])
        }
        .width(40)
        .height(40)
        .backgroundColor(this.showChapterNav ? '#E8F4FF' : '#FFFFFF')
        .borderRadius(20)
        .onClick(() => {
          this.showChapterNav = !this.showChapterNav;
        })
      }

      // Menu
      Button({ type: ButtonType.Normal }) {
        Text('···')
          .fontSize(18)
          .fontColor('#666666')
          .fontWeight(FontWeight.Bold)
      }
      .width(40)
      .height(40)
      .backgroundColor('#FFFFFF')
      .borderRadius(20)
      .onClick(() => {
        this.showActionMenu = !this.showActionMenu;
        if (!this.showActionMenu) this.showReadingSettings = false;
      })
    }
    .width('100%')
    .height(56)
    .padding({ left: 8, right: 12 })
    .backgroundColor('#FFFFFF')
    .shadow({
      radius: 2,
      color: 'rgba(0, 0, 0, 0.04)',
      offsetX: 0,
      offsetY: 1
    })
  }

  // ========== Loading View ==========

  @Builder
  private LoadingView() {
    Column() {
      SymbolGlyph($r('sys.symbol.arrow_clockwise'))
        .fontSize(36)
        .fontColor(['#CCCCCC'])
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ========== Error View ==========

  @Builder
  private ErrorView() {
    Column() {
      SymbolGlyph($r('sys.symbol.doc_text'))
        .fontSize(48)
        .fontColor(['#CCCCCC'])
      Text(this.errorText.length > 0 ? this.errorText : '笔记不存在')
        .fontSize(14)
        .fontColor('#999999')
        .margin({ top: 12 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ========== Reader View ==========

  @Builder
  private ReaderView() {
    Stack() {
      Scroll() {
        Column() {
          // Title
          Text(this.note?.title ?? '无标题')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor)
            .width('100%')
            .padding({ bottom: 8 })

          // Meta row
          Row() {
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.clock'))
                .fontSize(12)
                .fontColor(['#AAAAAA'])
              Text(this.formatDate(this.note?.createdAt ?? 0))
                .fontSize(12)
                .fontColor('#AAAAAA')
            }

            if (this.note && typeof this.note.folderId === 'string' && this.note.folderId.length > 0) {
              Row({ space: 4 }) {
                SymbolGlyph($r('sys.symbol.folder'))
                  .fontSize(12)
                  .fontColor(['#AAAAAA'])
                  .margin({ left: 12 })
                Text(this.folderNameById(this.note.folderId))
                  .fontSize(12)
                  .fontColor('#AAAAAA')
              }
            }

            if (this.note?.sourceUrl) {
              Text('查看原文')
                .fontSize(12)
                .fontColor('#007DFF')
                .margin({ left: 12 })
                .onClick(() => {
                  promptAction.showToast({ message: '来源: ' + this.note?.sourceUrl });
                })
            }
          }
          .width('100%')
          .padding({ bottom: 8 })

          if (this.note && Array.isArray(this.note.tags) && this.note.tags.length > 0) {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.note.tags, (tag: string) => {
                Text(tag)
                  .fontSize(12)
                  .fontColor('#007DFF')
                  .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                  .backgroundColor('#E8F4FF')
                  .borderRadius(10)
                  .margin({ right: 6, top: 6 })
              })
            }
            .width('100%')
            .padding({ bottom: 16 })
          }

          Divider()
            .height(1)
            .color('#E8E8E8')
            .width('100%')
            .margin({ bottom: 16 })

          ForEach(this.parsedBlocks, (block: MarkdownBlock, index: number) => {
            this.RenderBlock(block, index, this.headingAnchorMap[index])
          }, (block: MarkdownBlock, index: number) => `${index}_${block.type}`)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 20, bottom: 40 })
        .backgroundColor(this.bgColor)
        .onAreaChange((_oldValue: Area, newValue: Area) => {
          this.contentHeight = newValue.height as number;
        })
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .onScroll((offset: number, _state: ScrollState) => {
        this.scrollOffset = offset;
      })
      .onScrollStop(() => {
        this.saveProgress();
      })

      if (this.progressPercent > 0) {
        Text(this.progressPercent + '%')
          .fontSize(11)
          .fontColor('#FFFFFF')
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor('rgba(0, 125, 255, 0.7)')
          .borderRadius(10)
          .position({ bottom: 16, right: 16 })
      }
    }
    .layoutWeight(1)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      if (newValue.height as number > 0) {
        this.viewportHeight = newValue.height as number;
      }
    })
  }

  private buildHeadingAnchorMap(): Record<number, string> {
    const map: Record<number, string> = {};
    const blocks = this.parsedBlocks;
    let chCount: number = 0;
    for (let i = 0; i < blocks.length; i++) {
      const b = blocks[i];
      if (b.type === 'h1' || b.type === 'h2' || b.type === 'h3') {
        chCount++;
        map[i] = 'ch_' + chCount;
      }
    }
    return map;
  }

  // @Builder-compatible getter (no const declarations inside @Builder)
  private get headingAnchorMap(): Record<number, string> {
    return this.buildHeadingAnchorMap();
  }

  private folderNameById(id: string): string {
    for (const f of this.folders) {
      if (f.id === id) return f.name;
    }
    return '';
  }

  // ========== Markdown Render Block ==========

  @Builder
  private RenderBlock(block: MarkdownBlock, _index: number, chapterAnchor?: string) {
    if (block.type === 'empty') {
      Text(' ')
        .fontSize(8)
        .width('100%')
    } else if (block.type === 'h1') {
      Text(block.content)
        .id(chapterAnchor ?? '')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.textColor)
        .width('100%')
        .padding({ top: 16, bottom: 8 })
        .onAreaChange((_ov: Area, nv: Area) => {
          if (chapterAnchor && nv.position) {
            this.headingPositions[chapterAnchor] = nv.position.y as number;
          }
        })
    } else if (block.type === 'h2') {
      Text(block.content)
        .id(chapterAnchor ?? '')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.textColor)
        .width('100%')
        .padding({ top: 14, bottom: 6 })
        .onAreaChange((_ov: Area, nv: Area) => {
          if (chapterAnchor && nv.position) {
            this.headingPositions[chapterAnchor] = nv.position.y as number;
          }
        })
    } else if (block.type === 'h3') {
      Text(block.content)
        .id(chapterAnchor ?? '')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.textColor)
        .width('100%')
        .padding({ top: 12, bottom: 4 })
        .onAreaChange((_ov: Area, nv: Area) => {
          if (chapterAnchor && nv.position) {
            this.headingPositions[chapterAnchor] = nv.position.y as number;
          }
        })
    } else if (block.type === 'h4' || block.type === 'h5' || block.type === 'h6') {
      Text(block.content)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.textColor)
        .width('100%')
        .padding({ top: 8, bottom: 4 })
    } else if (block.type === 'blockquote') {
      Text(block.content)
        .fontSize(this.readingFontSize)
        .fontColor('#666666')
        .fontStyle(FontStyle.Italic)
        .width('100%')
        .padding({ left: 14, top: 8, bottom: 8, right: 8 })
        .borderWidth({ left: 3 })
        .borderColor({ left: '#007DFF' })
        .borderStyle({ left: BorderStyle.Solid })
        .backgroundColor('#F8F9FA')
        .borderRadius(4)
        .margin({ top: 4, bottom: 4 })
    } else if (block.type === 'codeblock') {
      Column() {
        Text(block.content)
          .fontSize(Math.max(this.readingFontSize - 2, 13))
          .fontColor('#E8E8E8')
          .width('100%')
          .fontFamily('monospace')
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#1E1E2E')
      .borderRadius(8)
      .margin({ top: 4, bottom: 4 })
    } else if (block.type === 'unordered-list') {
      Row() {
        Text('•')
          .fontSize(this.readingFontSize)
          .fontColor('#007DFF')
        Text(block.content)
          .fontSize(this.readingFontSize)
          .fontColor(this.textColor)
          .layoutWeight(1)
          .margin({ left: 6 })
      }
      .width('100%')
      .padding({ left: 8, top: 2, bottom: 2 })
    } else if (block.type === 'ordered-list') {
      Row() {
        Text(block.level + '.')
          .fontSize(this.readingFontSize)
          .fontColor('#666666')
        Text(block.content)
          .fontSize(this.readingFontSize)
          .fontColor(this.textColor)
          .layoutWeight(1)
          .margin({ left: 6 })
      }
      .width('100%')
      .padding({ left: 8, top: 2, bottom: 2 })
    } else if (block.type === 'hr') {
      Divider()
        .height(1)
        .color('#E0E0E0')
        .width('100%')
        .margin({ top: 12, bottom: 12 })
    } else {
      Text(block.content)
        .fontSize(this.readingFontSize)
        .fontColor(this.textColor)
        .width('100%')
        .padding({ top: 2, bottom: 2 })
    }
  }

  // ========== Editor View ==========

  @Builder
  private EditorView() {
    Column() {
      if (this.showPreview) {
        // Split: edit on top, preview on bottom
        Scroll() {
          TextArea({ text: this.editContent, placeholder: '开始写点什么...' })
            .height(600)
            .width('100%')
            .backgroundColor('#FFFFFF')
            .fontSize(15)
            .fontColor('#1A1A1A')
            .placeholderFont({ size: 15 })
            .placeholderColor('#CCCCCC')
            .borderRadius(0)
            .borderWidth(0)
            .padding(16)
            .onChange((value: string) => {
              this.editContent = value;
              this.onEditContentChange();
            })
        }
        .layoutWeight(1)
        .backgroundColor('#FFFFFF')

        Divider()
          .height(1)
          .color('#007DFF')
          .width('100%')

        Scroll() {
          Column() {
            ForEach(this.editPreviewBlocks, (block: MarkdownBlock, index: number) => {
              this.RenderBlock(block, index)
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 16 })
        }
        .layoutWeight(1)
        .backgroundColor('#FAFAFA')
      } else {
        Scroll() {
          Column() {
            TextInput({ text: this.editTitle, placeholder: '输入标题...' })
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .height(48)
              .width('100%')
              .backgroundColor('#FFFFFF')
              .borderRadius(8)
              .padding({ left: 12, right: 12 })
              .onChange((value: string) => {
                this.editTitle = value;
                this.onEditContentChange();
              })

            Divider()
              .height(1)
              .color('#F0F0F0')
              .width('100%')
              .margin({ top: 8, bottom: 8 })

            TextArea({ text: this.editContent, placeholder: '开始写点什么...\n\n支持 Markdown 语法：# 标题、**加粗**、- 列表等' })
              .height(800)
              .width('100%')
              .backgroundColor('#FFFFFF')
              .fontSize(15)
              .fontColor('#333333')
              .placeholderFont({ size: 15 })
              .placeholderColor('#CCCCCC')
              .borderRadius(0)
              .borderWidth(0)
              .padding(12)
              .onChange((value: string) => {
                this.editContent = value;
                this.onEditContentChange();
              })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .backgroundColor('#FFFFFF')
      }

      // Editor Toolbar
      Scroll() {
        Row() {
          ForEach(TOOLBAR_ITEMS, (item: ToolbarItem) => {
            Button({ type: ButtonType.Normal }) {
              Text(item.label)
                .fontSize(13)
                .fontColor('#333333')
                .fontWeight(FontWeight.Medium)
            }
            .height(32)
            .padding({ left: 10, right: 10 })
            .backgroundColor('#F0F0F0')
            .borderRadius(6)
            .margin({ right: 6 })
            .onClick(() => {
              this.editContent += (item.newLineBefore ? '\n' : '') + item.insertBefore + item.insertAfter + (item.newLineAfter ? '\n' : '');
              this.onEditContentChange();
            })
          })

          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.eye'))
              .fontSize(16)
              .fontColor([this.showPreview ? '#007DFF' : '#999999'])
          }
          .width(32)
          .height(32)
          .backgroundColor(this.showPreview ? '#E8F4FF' : '#F0F0F0')
          .borderRadius(6)
          .onClick(() => {
            this.showPreview = !this.showPreview;
          })

          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.list_bullet'))
              .fontSize(16)
              .fontColor([this.showEditChapterOutline ? '#007DFF' : '#999999'])
          }
          .width(32)
          .height(32)
          .backgroundColor(this.showEditChapterOutline ? '#E8F4FF' : '#F0F0F0')
          .borderRadius(6)
          .onClick(() => {
            this.showEditChapterOutline = !this.showEditChapterOutline;
          })
        }
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .height(44)
      .backgroundColor('#F8F9FA')

      // Edit chapter outline
      if (this.showEditChapterOutline) {
        this.EditChapterOutline()
      }

      // Stats row
      Row() {
        Text(`${this.countCharacters(this.editContent)} 字`)
          .fontSize(12)
          .fontColor('#AAAAAA')
          .margin({ left: 4 })

        SymbolGlyph($r('sys.symbol.clock'))
          .fontSize(12)
          .fontColor(['#AAAAAA'])
          .margin({ left: 12 })
        Text(`阅读 ${this.estimatedReadMinutes(this.editContent)} 分钟`)
          .fontSize(12)
          .fontColor('#AAAAAA')
          .margin({ left: 4 })

        Blank()
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .backgroundColor('#F8F9FA')

      // Folder select
      Row() {
        SymbolGlyph($r('sys.symbol.folder'))
          .fontSize(14)
          .fontColor(['#999999'])
        Text(this.editFolderId.length > 0 ? this.folderNameById(this.editFolderId) : '不分组')
          .fontSize(13)
          .fontColor(this.editFolderId.length > 0 ? '#5F27CD' : '#999999')
          .margin({ left: 6 })
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(12)
          .fontColor(['#CCCCCC'])
      }
      .width('100%')
      .height(36)
      .padding({ left: 16, right: 16 })
      .backgroundColor('#FFFFFF')
      .onClick(() => {
        this.showFolderPicker = !this.showFolderPicker;
        this.showTagInput = false;
      })

      if (this.showFolderPicker) {
        this.FolderPicker()
      }

      // Tags
      Row() {
        SymbolGlyph($r('sys.symbol.label'))
          .fontSize(14)
          .fontColor(['#999999'])
        Text(this.editTags.length > 0 ? this.editTags.join(', ') : '添加标签')
          .fontSize(13)
          .fontColor(this.editTags.length > 0 ? '#007DFF' : '#999999')
          .margin({ left: 6 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(12)
          .fontColor(['#CCCCCC'])
      }
      .width('100%')
      .height(36)
      .padding({ left: 16, right: 16 })
      .backgroundColor('#FFFFFF')
      .onClick(() => {
        this.showTagInput = !this.showTagInput;
        this.showFolderPicker = false;
      })

      if (this.showTagInput) {
        this.TagEditor()
      }
    }
    .layoutWeight(1)
  }

  // ========== Folder Picker ==========

  @Builder
  private FolderPicker() {
    Scroll() {
      Column() {
        Row() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(14)
            .fontColor(['#007DFF'])
          Text('不分组')
            .fontSize(14)
            .fontColor('#333333')
            .margin({ left: 8 })
        }
        .width('100%')
        .height(40)
        .padding({ left: 16 })
        .onClick(() => {
          this.editFolderId = '';
          this.showFolderPicker = false;
          this.onEditContentChange();
        })

        ForEach(this.folders, (folder: NoteFolder) => {
          Row() {
            SymbolGlyph($r('sys.symbol.folder'))
              .fontSize(14)
              .fontColor(['#007DFF'])
            Text(folder.name)
              .fontSize(14)
              .fontColor('#333333')
              .layoutWeight(1)
              .margin({ left: 8 })
            if (folder.id === this.editFolderId) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(14)
                .fontColor(['#007DFF'])
            }
          }
          .width('100%')
          .height(40)
          .padding({ left: 16, right: 16 })
          .onClick(() => {
            this.editFolderId = folder.id;
            this.showFolderPicker = false;
            this.onEditContentChange();
          })
        })
      }
      .width('100%')
    }
    .height(Math.min((this.folders.length + 1) * 40, 240))
    .width('100%')
    .backgroundColor('#FFFFFF')
    .border({ radius: 8 })
    .shadow({
      radius: 4,
      color: 'rgba(0, 0, 0, 0.08)',
      offsetX: 0,
      offsetY: 2
    })
  }

  // ========== Tag Editor ==========

  @Builder
  private TagEditor() {
    Column() {
      if (this.editTags.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.editTags, (tag: string, index: number) => {
            Row({ space: 4 }) {
              Text(tag)
                .fontSize(13)
                .fontColor('#007DFF')
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(11)
                .fontColor(['#999999'])
                .onClick(() => {
                  this.removeTag(index);
                })
            }
            .padding({ left: 10, right: 8, top: 4, bottom: 4 })
            .backgroundColor('#E8F4FF')
            .borderRadius(14)
            .margin({ right: 6, top: 6 })
          })
        }
        .width('100%')
        .padding({ bottom: 8 })
      }

      Row({ space: 8 }) {
        TextInput({ text: this.newTagInput, placeholder: '输入标签后确认' })
          .height(32)
          .layoutWeight(1)
          .backgroundColor('#F5F5F5')
          .borderRadius(8)
          .placeholderFont({ size: 13 })
          .placeholderColor('#CCCCCC')
          .fontSize(13)
          .padding({ left: 8, right: 8 })
          .onChange((value: string) => {
            this.newTagInput = value;
          })
          .onSubmit(() => {
            this.addTag();
          })
        Button('添加')
          .fontSize(13)
          .fontColor('#FFFFFF')
          .height(32)
          .padding({ left: 12, right: 12 })
          .backgroundColor('#007DFF')
          .borderRadius(8)
          .onClick(() => {
            this.addTag();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .border({ radius: 8 })
    .shadow({
      radius: 4,
      color: 'rgba(0, 0, 0, 0.08)',
      offsetX: 0,
      offsetY: 2
    })
  }

  // ========== Edit Chapter Outline ==========

  @Builder
  private EditChapterOutline() {
    Column() {
      Row() {
        Text('章节大纲')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1A1A1A')
        Text(this.editChapters.length + '章')
          .fontSize(11)
          .fontColor('#007DFF')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor('#E8F4FF')
          .borderRadius(6)
          .margin({ left: 8 })
        Text('(编辑 # 标题以修改)')
          .fontSize(11)
          .fontColor('#CCCCCC')
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .padding({ bottom: 8 })

      if (this.editChapters.length === 0) {
        Text('暂无章节，使用 # ## ### 标记标题')
          .fontSize(12)
          .fontColor('#CCCCCC')
          .padding({ top: 8, bottom: 8 })
      } else {
        ForEach(this.editChapters, (ch: Chapter, idx: number) => {
          Row() {
            Text('H' + ch.level)
              .fontSize(10)
              .fontColor('#FFFFFF')
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .backgroundColor(ch.level === 1 ? '#5F27CD' : ch.level === 2 ? '#007DFF' : '#2ED573')
              .borderRadius(4)
            Text(ch.title)
              .fontSize(13)
              .fontColor('#333333')
              .layoutWeight(1)
              .margin({ left: 8 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding({ left: 8, top: 6, bottom: 6, right: 8 })
          .borderRadius(6)
        }, (ch: Chapter, idx: number) => 'outline_' + idx + '_' + ch.anchor)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .border({ radius: 8 })
    .shadow({
      radius: 4,
      color: 'rgba(0, 0, 0, 0.08)',
      offsetX: 0,
      offsetY: 2
    })
  }

  // ========== Chapter Navigation Panel ==========

  @Builder
  private ChapterNavPanel() {
    Column() {
      Row() {
        Row({ space: 8 }) {
          Text('目录')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
          Text(this.chapters.length + '章')
            .fontSize(12)
            .fontColor('#007DFF')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor('#E8F4FF')
            .borderRadius(8)
        }
        .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(16)
          .fontColor(['#999999'])
          .onClick(() => {
            this.showChapterNav = false;
          })
      }
      .width('100%')
      .padding({ bottom: 12 })

      Divider()
        .height(1)
        .color('#F0F0F0')
        .width('100%')
        .margin({ bottom: 8 })

      Scroll() {
        Column() {
          ForEach(this.chapters, (chapter: Chapter, index: number) => {
            Row() {
              Column()
                .width(3)
                .height('80%')
                .backgroundColor(this.isCurrentChapter(index) ? '#007DFF' :
                  chapter.level === 1 ? '#5F27CD' :
                  chapter.level === 2 ? '#007DFF' : '#2ED573')
                .borderRadius(2)

              Row() {
                Text(chapter.title)
                  .fontSize(chapter.level === 1 ? 14 : 13)
                  .fontColor(this.isCurrentChapter(index) ? '#007DFF' : '#333333')
                  .fontWeight(chapter.level === 1 ? FontWeight.Medium : FontWeight.Regular)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ left: 10 })

                if (this.isCurrentChapter(index)) {
                  SymbolGlyph($r('sys.symbol.book'))
                    .fontSize(12)
                    .fontColor(['#007DFF'])
                    .margin({ left: 4 })
                }
              }
              .layoutWeight(1)
            }
            .width('100%')
            .padding({
              left: 8 + Math.min(chapter.level - 1, 3) * 16,
              top: 6,
              bottom: 6,
              right: 8
            })
            .backgroundColor(this.isCurrentChapter(index) ? '#F0F7FF' : 'transparent')
            .borderRadius(8)
            .onClick(() => {
              if (this.isEditing) return;
              this.showChapterNav = false;
            })
          }, (chapter: Chapter) => chapter.anchor)
        }
        .width('100%')
      }
      .layoutWeight(1)
    }
    .width(300)
    .height('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .shadow({
      radius: 12,
      color: 'rgba(0, 0, 0, 0.1)',
      offsetX: -4,
      offsetY: 0
    })
    .alignSelf(ItemAlign.Start)
  }

  // ========== Reading Settings Bar ==========

  @Builder
  private ReadingSettingsBar() {
    Column() {
      Divider()
        .height(1)
        .color('#E8E8E8')
        .width('100%')

      Scroll() {
        Column({ space: 8 }) {
          // Background mode
          Row({ space: 8 }) {
            Text('背景')
              .fontSize(12)
              .fontColor('#999999')
            ForEach(BG_MODES, (mode: BgModeOption) => {
              Row({ space: 4 }) {
                Column()
                  .width(14)
                  .height(14)
                  .backgroundColor(mode.bg)
                  .borderRadius(7)
                  .border({
                    width: this.bgMode === mode.key ? 2 : 1,
                    color: this.bgMode === mode.key ? '#007DFF' : '#DDDDDD'
                  })
                Text(mode.label)
                  .fontSize(12)
                  .fontColor(this.bgMode === mode.key ? '#007DFF' : '#666666')
              }
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor(this.bgMode === mode.key ? '#E8F4FF' : '#F5F5F5')
              .borderRadius(6)
              .onClick(() => {
                this.bgMode = mode.key;
              })
            })
          }
          .width('100%')

          // Font size
          Row({ space: 8 }) {
            Text('字号')
              .fontSize(12)
              .fontColor('#999999')
            ForEach(FONT_SIZES, (fs: FontSizeOption) => {
              Text(fs.label)
                .fontSize(12)
                .fontColor(this.readingFontSize === fs.value ? '#FFFFFF' : '#666666')
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .backgroundColor(this.readingFontSize === fs.value ? '#007DFF' : '#F0F0F0')
                .borderRadius(6)
                .onClick(() => {
                  this.readingFontSize = fs.value;
                })
            })
          }
          .width('100%')

          // Line height
          Row({ space: 8 }) {
            Text('行距')
              .fontSize(12)
              .fontColor('#999999')
            ForEach(LINE_HEIGHTS, (lh: LineHeightOption) => {
              Text(lh.label)
                .fontSize(12)
                .fontColor(this.readingLineHeight === lh.value ? '#FFFFFF' : '#666666')
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .backgroundColor(this.readingLineHeight === lh.value ? '#007DFF' : '#F0F0F0')
                .borderRadius(6)
                .onClick(() => {
                  this.readingLineHeight = lh.value;
                })
            })
          }
          .width('100%')
        }
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .backgroundColor('#FFFFFF')
    }
  }

  // ========== Action Menu Overlay ==========

  @Builder
  private ActionMenuOverlay() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.001)')
        .onClick(() => {
          this.showActionMenu = false;
          this.showReadingSettings = false;
        })

      Column({ space: 6 }) {
        Button('保存')
          .width(160)
          .height(34)
          .fontSize(12)
          .fontColor('#FFFFFF')
          .backgroundColor('#007DFF')
          .borderRadius(6)
          .enabled(this.isEditing && this.note !== null)
          .opacity(this.isEditing ? 1 : 0.5)
          .onClick(async () => {
            await this.flushAutoSave();
            this.showActionMenu = false;
          })
        Button('保存并返回')
          .width(160)
          .height(34)
          .fontSize(12)
          .fontColor('#FFFFFF')
          .backgroundColor('#1E5AA7')
          .borderRadius(6)
          .enabled(this.isEditing && this.note !== null)
          .opacity(this.isEditing ? 1 : 0.5)
          .onClick(async () => {
            this.showActionMenu = false;
            const ok = await this.persistCurrentNote(true);
            if (ok) router.back();
          })
        Button('删除')
          .width(160)
          .height(34)
          .fontSize(12)
          .fontColor(this.isNew ? '#CCCCCC' : '#FF4757')
          .backgroundColor(this.isNew ? '#F5F5F5' : '#FFF0F0')
          .borderRadius(6)
          .enabled(!this.isNew)
          .onClick(() => {
            this.showActionMenu = false;
            this.confirmDelete();
          })
        Divider()
          .height(1)
          .color('#F0F0F0')
          .width('100%')
        Button('复制正文')
          .width(160)
          .height(34)
          .fontSize(12)
          .fontColor('#666666')
          .backgroundColor('#F0F0F0')
          .borderRadius(6)
          .enabled(this.editContent.length > 0)
          .onClick(() => {
            this.copyContent();
            this.showActionMenu = false;
          })
        Button('复制标题')
          .width(160)
          .height(34)
          .fontSize(12)
          .fontColor('#666666')
          .backgroundColor('#F0F0F0')
          .borderRadius(6)
          .enabled(this.editTitle.trim().length > 0)
          .onClick(() => {
            this.copyTitle();
            this.showActionMenu = false;
          })
        Button('复制标题+正文')
          .width(160)
          .height(34)
          .fontSize(12)
          .fontColor('#666666')
          .backgroundColor('#F0F0F0')
          .borderRadius(6)
          .enabled(this.editTitle.trim().length > 0 || this.editContent.length > 0)
          .onClick(() => {
            this.copyTitleAndContent();
            this.showActionMenu = false;
          })
        if (!this.isEditing) {
          Divider()
            .height(1)
            .color('#F0F0F0')
            .width('100%')
          Button(this.showReadingSettings ? '收起阅读设置' : '阅读设置')
            .width(160)
            .height(34)
            .fontSize(12)
            .fontColor('#007DFF')
            .backgroundColor('#E8F4FF')
            .borderRadius(6)
            .onClick(() => {
              this.showReadingSettings = !this.showReadingSettings;
            })
        }
      }
      .padding(8)
      .backgroundColor('#FFFFFF')
      .borderRadius(10)
      .shadow({
        radius: 8,
        color: 'rgba(0, 0, 0, 0.12)',
        offsetX: 0,
        offsetY: 2
      })
      .margin({ top: 52, right: 12 })
    }
    .width('100%')
    .height('100%')
  }
}
