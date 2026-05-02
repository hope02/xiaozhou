import { common } from '@kit.AbilityKit';
import { promptAction, router, Scroller } from '@kit.ArkUI';
import { Note, NoteFolder, Chapter, NoteType } from '../model/Note';
import { NoteRepository } from '../repository/NoteRepository';
import { PreferencesNoteRepository } from '../repository/PreferencesNoteRepository';

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

const CHAPTER_HEADING_DEPTH: number = 2;
const AUTO_SAVE_DELAY: number = 3000;

@Entry
@Component
struct NoteDetailPage {
  @State note: Note | null = null;
  @State isLoading: boolean = true;
  @State isEditing: boolean = false;
  @State isNew: boolean = false;
  @State editTitle: string = '';
  @State editContent: string = '';
  @State showChapterNav: boolean = false;
  @State fontSizeValue: number = 16;
  @State lineHeightValue: number = 1.7;
  @State bgMode: string = 'white';
  @State scrollOffset: number = 0;
  @State contentHeight: number = 0;
  @State viewportHeight: number = 0;
  @State saveIndicator: string = '';
  @State folders: NoteFolder[] = [];
  @State showFolderPicker: boolean = false;
  @State editFolderId: string = '';
  @State editTags: string[] = [];
  @State newTagInput: string = '';
  @State showTagInput: boolean = false;
  @State showPreview: boolean = false;
  @State showEditChapterOutline: boolean = false;
  @State editingChapterIndex: number = -1;
  @State editingChapterInput: string = '';

  private noteRepo: NoteRepository | null = null;
  private noteId: string = '';
  private autoSaveTimer: number | null = null;
  private dirtyFlag: boolean = false;
  private isHandlingBack: boolean = false;
  private scroller: Scroller = new Scroller();
  private headingPositions: Record<string, number> = {};

  private readonly toolbarItems: ToolbarItem[] = [
    { label: 'H1', insertBefore: '# ', insertAfter: '', newLineBefore: true, newLineAfter: true },
    { label: 'H2', insertBefore: '## ', insertAfter: '', newLineBefore: true, newLineAfter: true },
    { label: 'H3', insertBefore: '### ', insertAfter: '', newLineBefore: true, newLineAfter: true },
    { label: 'B', insertBefore: '**', insertAfter: '**', newLineBefore: false, newLineAfter: false },
    { label: 'I', insertBefore: '*', insertAfter: '*', newLineBefore: false, newLineAfter: false },
    { label: '`', insertBefore: '`', insertAfter: '`', newLineBefore: false, newLineAfter: false },
    { label: '>', insertBefore: '> ', insertAfter: '', newLineBefore: true, newLineAfter: true },
    { label: '-', insertBefore: '- ', insertAfter: '', newLineBefore: true, newLineAfter: false },
    { label: '1.', insertBefore: '1. ', insertAfter: '', newLineBefore: true, newLineAfter: false },
    { label: '---', insertBefore: '\n---\n', insertAfter: '', newLineBefore: false, newLineAfter: false },
  ];

  aboutToAppear(): void {
    try {
      const params = router.getParams() as Record<string, string>;
      this.noteId = params?.['noteId'] ?? '';
      this.isNew = params?.['isNew'] === 'true';
      console.info('NoteDetailPage initializing, noteId:', this.noteId, 'isNew:', this.isNew);
      const context = getContext(this) as common.UIAbilityContext;
      this.noteRepo = new PreferencesNoteRepository(context);
      this.loadFolders();
      if (this.isNew) {
        this.isEditing = true;
        this.editTitle = '';
        this.editContent = '';
        this.editTags = [];
        this.isLoading = false;
      } else {
        this.loadNote();
      }
    } catch (e) {
      console.error('Failed to initialize NoteDetailPage:', e);
      promptAction.showToast({ message: '初始化失败' });
      router.back();
    }
  }

  onPageShow(): void {
    if (this.noteId && !this.isNew) {
      this.loadNote();
    }
    // Folder names may change in manager page; refresh to avoid stale labels.
    this.loadFolders();
  }

  onPageHide(): void {
    // Best-effort: page hide can't block navigation; persist in background.
    this.flushAutoSave();
  }

  onBackPress(): boolean {
    // Intercept system back to avoid "saved but not in list" race (save is async).
    if (this.isHandlingBack) {
      return true;
    }
    this.isHandlingBack = true;
    void this.saveThenBack();
    return true;
  }

  private async saveThenBack(): Promise<void> {
    try {
      await this.flushAutoSaveAsync();
    } catch (_) {
      // ignore
    }
    router.back();
    this.isHandlingBack = false;
  }

  private async loadNote(): Promise<void> {
    if (!this.noteRepo || !this.noteId) {
      this.isLoading = false;
      return;
    }
    try {
      this.note = await this.noteRepo.getNoteById(this.noteId);
      const n = this.note;
      if (n) {
        this.editTitle = n.title;
        this.editContent = n.content;
        this.editFolderId = n.folderId ?? '';
        this.editTags = n.tags ? n.tags.slice() : [];
      }
    } catch (_) {
      this.note = null;
    }
    this.isLoading = false;
  }

  private async loadFolders(): Promise<void> {
    if (!this.noteRepo) {
      return;
    }
    try {
      this.folders = await this.noteRepo.listFolders();
    } catch (_) {
      this.folders = [];
    }
  }

  // ----- computed values -----

  private get readingProgress(): number {
    if (this.contentHeight <= 0 || this.viewportHeight <= 0) {
      return 0;
    }
    const maxScroll = Math.max(this.contentHeight - this.viewportHeight, 1);
    return Math.min(Math.round((this.scrollOffset / maxScroll) * 100), 100);
  }

  private get bgColor(): string {
    if (this.bgMode === 'paper') return '#F5F0E8';
    if (this.bgMode === 'gray') return '#F0F0F0';
    if (this.bgMode === 'dark') return '#1A1A2E';
    return '#FFFFFF';
  }

  private get textColor(): string {
    return this.bgMode === 'dark' ? '#E0E0E0' : '#1A1A1A';
  }

  private get currentFolderLabel(): string {
    const id = this.isEditing ? this.editFolderId : (this.note?.folderId ?? '');
    if (id.length === 0) return '不分组';
    for (const f of this.folders) {
      if (f.id === id) return f.name;
    }
    return '不分组';
  }

  private get readerFolderName(): string {
    const id = this.note?.folderId ?? '';
    if (id.length === 0) return '';
    for (const f of this.folders) {
      if (f.id === id) return f.name;
    }
    return '';
  }

  private get progressPercent(): number {
    const p = this.readingProgress;
    if (p > 0 && p < 100) return p;
    return 0;
  }

  private get showChapterButton(): boolean {
    return this.chapterCount > 1;
  }

  private get chapterCount(): number {
    return this.chapters.length;
  }

  private get previewBlocks(): MarkdownBlock[] {
    return this.parseMarkdown(this.editContent);
  }

  private get parsedBlocks(): MarkdownBlock[] {
    return this.parseMarkdown(this.note?.content ?? '');
  }

  private get chapters(): Chapter[] {
    const meta = this.note?.importMeta;
    if (meta && meta.chapters.length > 0) {
      return meta.chapters;
    }
    return this.extractChapters(this.parsedBlocks);
  }

  private get editChapters(): Chapter[] {
    return this.extractChapters(this.parseMarkdown(this.editContent));
  }
    const map: Record<number, string> = {};
    let chCount: number = 0;
    for (let i = 0; i < this.parsedBlocks.length; i++) {
      const b = this.parsedBlocks[i];
      if (b.type === 'h1' || b.type === 'h2' || b.type === 'h3') {
        chCount++;
        map[i] = 'ch_' + chCount;
      }
    }
    return map;
  }

  private get currentChapterIndex(): number {
    const n: number = this.chapters.length;
    for (let i: number = n - 1; i >= 0; i--) {
      const pos: number | undefined = this.headingPositions['ch_' + (i + 1)];
      if (pos !== undefined && pos <= this.scrollOffset + 80) {
        return i;
      }
    }
    return -1;
  }

  // ----- build -----

  build() {
    Stack() {
      Column() {
        this.TopBar()
        this.BodyArea()
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F5F7FA')

      if (this.showChapterNav && this.chapters.length > 0) {
        this.ChapterNavPanel()
      }
    }
    .width('100%')
    .height('100%')
  }

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
      .onClick(() => {
        if (this.isHandlingBack) {
          return;
        }
        this.isHandlingBack = true;
        void this.saveThenBack();
      })

      Column() {
        if (this.isEditing) {
          TextInput({ text: this.editTitle, placeholder: '标题' })
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1A1A1A')
            .placeholderFont({ size: 16 })
            .placeholderColor('#CCCCCC')
            .height(36)
            .backgroundColor('#FFFFFF')
            .onChange((value: string) => {
              this.editTitle = value;
              this.triggerAutoSave();
            })
        } else {
          Text(this.note?.title ?? '笔记')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1A1A1A')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (!this.isEditing && this.note) {
          Text(this.note.type === 'import' ? '只读文档' :
            this.note.type === 'web_clip' ? '网页摘录' : '笔记')
            .fontSize(11)
            .fontColor('#999999')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.saveIndicator.length > 0) {
        Text(this.saveIndicator)
          .fontSize(11)
          .fontColor('#999999')
      }

      // 编辑/切换按钮
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
          .onClick(() => {
            this.flushAutoSave();
            this.applyEditToNote();
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

      // 目录
      if (this.showChapterButton) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.list_bullet'))
            .fontSize(18)
            .fontColor(['#666666'])
        }
        .width(40)
        .height(40)
        .backgroundColor('#FFFFFF')
        .borderRadius(20)
        .onClick(() => {
          this.showChapterNav = !this.showChapterNav;
        })
      }

      // 删除
      if (!this.isEditing && !this.isNew && this.note) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(17)
            .fontColor(['#FF4757'])
        }
        .width(40)
        .height(40)
        .backgroundColor('#FFF0F0')
        .borderRadius(20)
        .onClick(() => {
          this.confirmDelete();
        })
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: 8, right: 12 })
    .backgroundColor('#FFFFFF')
  }

  @Builder
  private BodyArea() {
    if (this.isLoading) {
      Column() {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(36)
          .fontColor(['#CCCCCC'])
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else if (!this.note && !this.isNew) {
      Column() {
        SymbolGlyph($r('sys.symbol.doc_text'))
          .fontSize(48)
          .fontColor(['#CCCCCC'])
        Text('笔记不存在')
          .fontSize(14)
          .fontColor('#999999')
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else if (this.isEditing) {
      this.EditorView()
    } else {
      this.ReaderView()
    }
  }

  @Builder
  private ReaderView() {
    Stack() {
      Scroll(this.scroller) {
        Column() {
          Text(this.note?.title ?? '无标题')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor)
            .width('100%')
            .padding({ bottom: 8 })

          Row() {
            Text(this.formatDate(this.note?.createdAt ?? 0))
              .fontSize(12)
              .fontColor('#999999')
            if (this.readerFolderName.length > 0) {
              Text(this.readerFolderName)
                .fontSize(12)
                .fontColor('#007DFF')
                .margin({ left: 12 })
            }
            if (this.note?.sourceUrl) {
              Text('查看原文')
                .fontSize(12)
                .fontColor('#007DFF')
                .margin({ left: 12 })
            }
          }
          .width('100%')
          .padding({ bottom: 8 })

          // 标签展示
          if (this.note && this.note.tags.length > 0) {
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
            .color('#F0F0F0')
            .width('100%')
            .padding({ bottom: 16 })

          const _anchorMap: Record<number, string> = this.headingAnchorMap;
          ForEach(this.parsedBlocks, (block: MarkdownBlock, index: number) => {
            this.RenderBlock(block, index, _anchorMap[index])
          }, (block: MarkdownBlock, index: number) => `${index}_${block.type}`)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 20, bottom: 40 })
        .backgroundColor(this.bgColor)
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .onScroll((offset: number, _state: ScrollState) => {
        this.scrollOffset = offset;
      })
      .onScrollStop(() => {
        this.saveProgress();
      })

      // 进度
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
  }

  @Builder
  private EditorView() {
    Column() {
      if (this.showPreview) {
        // 分屏：上编辑 + 下预览
        Scroll() {
          TextArea({ text: this.editContent, placeholder: '开始写点什么...' })
            .height(800)
            .width('100%')
            .backgroundColor('#FFFFFF')
            .fontSize(this.fontSizeValue)
            .fontColor('#1A1A1A')
            .placeholderFont({ size: this.fontSizeValue })
            .placeholderColor('#CCCCCC')
            .borderRadius(0)
            .borderWidth(0)
            .padding(16)
            .onChange((value: string) => {
              this.editContent = value;
              this.triggerAutoSave();
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
            ForEach(this.previewBlocks, (block: MarkdownBlock, index: number) => {
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
          TextArea({ text: this.editContent, placeholder: '开始写点什么...' })
            .height(1000)
            .width('100%')
            .backgroundColor('#FFFFFF')
            .fontSize(this.fontSizeValue)
            .fontColor('#1A1A1A')
            .placeholderFont({ size: this.fontSizeValue })
            .placeholderColor('#CCCCCC')
            .borderRadius(0)
            .borderWidth(0)
            .padding(16)
            .onChange((value: string) => {
              this.editContent = value;
              this.triggerAutoSave();
            })
        }
        .layoutWeight(1)
        .backgroundColor('#FFFFFF')
      }

      // 工具栏
      Scroll() {
        Row() {
          ForEach(this.toolbarItems, (item: ToolbarItem) => {
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
              this.triggerAutoSave();
            })
          })

          // 分屏预览切换
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

          // 章节目录
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

      // 编辑模式章节大纲
      if (this.showEditChapterOutline) {
        this.EditChapterOutline()
      }

      // 分组选择
      Row() {
        SymbolGlyph($r('sys.symbol.folder'))
          .fontSize(14)
          .fontColor(['#999999'])
        Text(this.currentFolderLabel)
          .fontSize(13)
          .fontColor('#666666')
          .margin({ left: 6 })
      }
      .width('100%')
      .height(36)
      .padding({ left: 16, right: 16 })
      .backgroundColor('#F8F9FA')
      .onClick(() => {
        this.showFolderPicker = !this.showFolderPicker;
      })

      // 分组选择弹出
      if (this.showFolderPicker) {
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
              this.triggerAutoSave();
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
                this.triggerAutoSave();
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

      // 标签管理
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
      }
      .width('100%')
      .height(36)
      .padding({ left: 16, right: 16 })
      .backgroundColor('#F8F9FA')
      .onClick(() => {
        this.showFolderPicker = false;
        this.showTagInput = !this.showTagInput;
      })

      // 标签编辑弹出
      if (this.showTagInput) {
        Column() {
          // 已有标签
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
                      this.editTags.splice(index, 1);
                      this.editTags = this.editTags.slice();
                      this.triggerAutoSave();
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

          // 添加标签输入
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
    }
    .layoutWeight(1)
  }

  @Builder
  private EditChapterOutline() {
    Column() {
      Row() {
        Text('章节大纲')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1A1A1A')
        Text(this.chapterCount + '章')
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
              .backgroundColor(ch.level === 1 ? '#5F27CD' :
                ch.level === 2 ? '#007DFF' : '#2ED573')
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

  @Builder
  private ChapterNavPanel() {
    Column() {
      // Header
      Row() {
        Row({ space: 8 }) {
          Text('目录')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
          Text(this.chapterCount + '章')
            .fontSize(12)
            .fontColor('#007DFF')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor('#E8F4FF')
            .borderRadius(8)
        }
        .layoutWeight(1)

        if (this.isEditing && this.chapters.length > 0) {
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(14)
              .fontColor(['#007DFF'])
          }
          .width(32)
          .height(32)
          .backgroundColor('#E8F4FF')
          .borderRadius(16)
          .margin({ right: 8 })
          .onClick(() => {
            this.syncChaptersFromContent();
          })
        }

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
            const isCurrent: boolean = !this.isEditing && index === this.currentChapterIndex;
            const isEditingChapter: boolean = this.isEditing && index === this.editingChapterIndex;

            Row() {
              // Level indicator bar
              Column()
                .width(3)
                .height('80%')
                .backgroundColor(isCurrent ? '#007DFF' :
                  chapter.level === 1 ? '#5F27CD' :
                  chapter.level === 2 ? '#007DFF' : '#2ED573')
                .borderRadius(2)

              Column() {
                if (isEditingChapter) {
                  // Inline edit mode
                  TextInput({ text: this.editingChapterInput, placeholder: '章节标题' })
                    .height(32)
                    .fontSize(14)
                    .fontColor('#1A1A1A')
                    .backgroundColor('#F5F5F5')
                    .borderRadius(6)
                    .padding({ left: 8, right: 8 })
                    .layoutWeight(1)
                    .onChange((v: string) => { this.editingChapterInput = v; })
                    .onSubmit(() => { this.confirmEditChapter(); })
                  Row({ space: 4 }) {
                    Button('确定')
                      .fontSize(11)
                      .fontColor('#FFFFFF')
                      .height(24)
                      .padding({ left: 8, right: 8 })
                      .backgroundColor('#007DFF')
                      .borderRadius(4)
                      .onClick(() => { this.confirmEditChapter(); })
                    Button('取消')
                      .fontSize(11)
                      .fontColor('#666666')
                      .height(24)
                      .padding({ left: 8, right: 8 })
                      .backgroundColor('#F0F0F0')
                      .borderRadius(4)
                      .onClick(() => { this.editingChapterIndex = -1; })
                  }
                } else {
                  // Display mode
                  Row() {
                    Text(chapter.title)
                      .fontSize(chapter.level === 1 ? 14 : 13)
                      .fontColor(isCurrent ? '#007DFF' : '#333333')
                      .fontWeight(chapter.level === 1 ? FontWeight.Medium : FontWeight.Regular)
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })

                    if (isCurrent) {
                      SymbolGlyph($r('sys.symbol.book'))
                        .fontSize(12)
                        .fontColor(['#007DFF'])
                        .margin({ left: 4 })
                    }

                    if (this.isEditing) {
                      Button({ type: ButtonType.Normal }) {
                        SymbolGlyph($r('sys.symbol.pencil'))
                          .fontSize(12)
                          .fontColor(['#999999'])
                      }
                      .width(24)
                      .height(24)
                      .backgroundColor('transparent')
                      .borderRadius(12)
                      .margin({ left: 4 })
                      .onClick(() => {
                        this.startEditChapter(index);
                      })
                    }
                  }
                }
              }
              .layoutWeight(1)
              .margin({ left: 10 })
            }
            .width('100%')
            .padding({
              left: 8 + Math.min(chapter.level - 1, 3) * 16,
              top: 6,
              bottom: 6,
              right: 8
            })
            .backgroundColor(isCurrent ? '#F0F7FF' : 'transparent')
            .borderRadius(8)
            .onClick(() => {
              if (this.isEditing || isEditingChapter) return;
              const anchor: string = 'ch_' + (index + 1);
              const pos: number | undefined = this.headingPositions[anchor];
              if (pos !== undefined) {
                this.scroller.scrollTo({ xOffset: 0, yOffset: Math.max(0, pos - 10) });
              }
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
        .onAreaChange((_ov, nv) => {
          if (chapterAnchor && nv.position) {
            this.headingPositions[chapterAnchor] = nv.position.y;
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
        .onAreaChange((_ov, nv) => {
          if (chapterAnchor && nv.position) {
            this.headingPositions[chapterAnchor] = nv.position.y;
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
        .onAreaChange((_ov, nv) => {
          if (chapterAnchor && nv.position) {
            this.headingPositions[chapterAnchor] = nv.position.y;
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
        .fontSize(this.fontSizeValue)
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
      Text(block.content)
        .fontSize(Math.max(this.fontSizeValue - 2, 13))
        .fontColor('#E8E8E8')
        .width('100%')
        .padding(12)
        .backgroundColor('#1E1E2E')
        .borderRadius(8)
        .fontFamily('monospace')
        .margin({ top: 4, bottom: 4 })
    } else if (block.type === 'unordered-list') {
      Row() {
        Text('•')
          .fontSize(this.fontSizeValue)
          .fontColor('#007DFF')
        Text(block.content)
          .fontSize(this.fontSizeValue)
          .fontColor(this.textColor)
          .layoutWeight(1)
          .margin({ left: 6 })
      }
      .width('100%')
      .padding({ left: 8, top: 2, bottom: 2 })
    } else if (block.type === 'ordered-list') {
      Row() {
        Text(block.level + '.')
          .fontSize(this.fontSizeValue)
          .fontColor('#666666')
        Text(block.content)
          .fontSize(this.fontSizeValue)
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
        .fontSize(this.fontSizeValue)
        .fontColor(this.textColor)
        .width('100%')
        .padding({ top: 2, bottom: 2 })
    }
  }

  // ----- markdown parser -----

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

      // headings
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
        const hContent: string = this.inlineFormat(trimmed.substring(contentStart).trim());
        blocks.push({ type: 'h' + level, content: hContent, level: 0 });
        listIndex = 0;
        continue;
      }

      // hr
      if (/^[-*_]{3,}$/.test(trimmed)) {
        blocks.push({ type: 'hr', content: '', level: 0 });
        listIndex = 0;
        continue;
      }

      // blockquote
      if (trimmed.startsWith('> ')) {
        blocks.push({ type: 'blockquote', content: this.inlineFormat(trimmed.substring(2)), level: 0 });
        listIndex = 0;
        continue;
      }

      // unordered list
      if (trimmed.startsWith('- ') || trimmed.startsWith('* ') || trimmed.startsWith('+ ')) {
        blocks.push({ type: 'unordered-list', content: this.inlineFormat(trimmed.substring(2)), level: 0 });
        listIndex = 0;
        continue;
      }

      // ordered list
      const dotIdx: number = trimmed.indexOf('. ');
      if (dotIdx > 0 && /^\d+$/.test(trimmed.substring(0, dotIdx))) {
        listIndex++;
        blocks.push({ type: 'ordered-list', content: this.inlineFormat(trimmed.substring(dotIdx + 2)), level: listIndex });
        continue;
      }

      // paragraph
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
        const last: MarkdownBlock = result[result.length - 1];
        if (last.type === 'paragraph') {
          last.content += ' ' + block.content;
          continue;
        }
      }
      result.push({
        type: block.type,
        content: block.content,
        level: block.level
      });
    }
    return result;
  }

  private extractChapters(blocks: MarkdownBlock[]): Chapter[] {
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

  // ----- chapter editing -----

  private startEditChapter(index: number): void {
    if (index < 0 || index >= this.chapters.length) return;
    this.editingChapterIndex = index;
    this.editingChapterInput = this.chapters[index].title;
  }

  private confirmEditChapter(): void {
    if (this.editingChapterIndex < 0) return;
    const idx: number = this.editingChapterIndex;
    const newTitle: string = this.editingChapterInput.trim();
    if (newTitle.length === 0) {
      this.editingChapterIndex = -1;
      return;
    }
    const chapters: Chapter[] = this.chapters;
    const oldTitle: string = chapters[idx].title;
    if (newTitle === oldTitle) {
      this.editingChapterIndex = -1;
      return;
    }
    // Update importMeta for import notes
    const meta = this.note?.importMeta;
    if (meta && meta.chapters.length > 0 && idx < meta.chapters.length) {
      meta.chapters[idx].title = newTitle;
    }
    // Update heading in markdown content
    this.updateHeadingInContent(idx, oldTitle, newTitle);
    this.editingChapterIndex = -1;
    this.triggerAutoSave();
  }

  private updateHeadingInContent(chapterIdx: number, _oldTitle: string, newTitle: string): void {
    const lines: string[] = this.editContent.split('\n');
    let headingCount: number = 0;
    for (let i = 0; i < lines.length; i++) {
      const trimmed: string = lines[i].trim();
      const match: RegExpMatchArray | null = trimmed.match(/^(#{1,3})\s+(.+)$/);
      if (match) {
        if (headingCount === chapterIdx) {
          lines[i] = match[1] + ' ' + newTitle;
          break;
        }
        headingCount++;
      }
    }
    this.editContent = lines.join('\n');
  }

  private syncChaptersFromContent(): void {
    const blocks: MarkdownBlock[] = this.parseMarkdown(this.editContent);
    const extracted: Chapter[] = this.extractChapters(blocks);
    const meta = this.note?.importMeta;
    if (meta) {
      meta.chapters = extracted;
      meta.chapterCount = extracted.length;
    }
    this.triggerAutoSave();
  }

  // ----- tag management -----

  private addTag(): void {
    const tag = this.newTagInput.trim();
    if (tag.length === 0) return;
    if (this.editTags.indexOf(tag) < 0) {
      this.editTags.push(tag);
      this.editTags = this.editTags.slice();
      this.triggerAutoSave();
    }
    this.newTagInput = '';
  }

  // ----- auto save -----

  private triggerAutoSave(): void {
    this.dirtyFlag = true;
    this.saveIndicator = '未保存';
    if (this.autoSaveTimer) {
      clearTimeout(this.autoSaveTimer);
      this.autoSaveTimer = null;
    }
    this.autoSaveTimer = setTimeout(() => {
      void this.flushAutoSaveAsync();
    }, AUTO_SAVE_DELAY);
  }

  private flushAutoSave(): void {
    // Legacy sync wrapper: keep API for existing calls.
    void this.flushAutoSaveAsync();
  }

  private async flushAutoSaveAsync(): Promise<void> {
    if (this.autoSaveTimer) {
      clearTimeout(this.autoSaveTimer);
      this.autoSaveTimer = null;
    }
    if (!this.dirtyFlag || !this.noteRepo) {
      return;
    }
    this.dirtyFlag = false;
    this.saveIndicator = '保存中...';
    if (this.isNew) {
      await this.createNote();
    } else {
      await this.updateNote();
    }
  }

  private async createNote(): Promise<void> {
    if (!this.noteRepo) {
      return;
    }
    const title: string = this.editTitle.trim() || this.extractTitleFromContent();
    const now: number = Date.now();
    const id: string = 'note_' + now + '_' + Math.random().toString(36).substring(2, 8);
    const plain: string = this.editContent.replace(/[#*`>\-\[\]()!]/g, '').substring(0, 200);
    const newNote: Note = {
      id: id,
      type: 'manual',
      title: title,
      content: this.editContent,
      tags: this.editTags.slice(),
      isFavorite: false,
      folderId: this.editFolderId.length > 0 ? this.editFolderId : undefined,
      readProgress: 0,
      createdAt: now,
      updatedAt: now,
      deletedFlag: false,
      contentPlain: plain
    };
    try {
      await this.noteRepo.upsertNote(newNote);
      this.note = newNote;
      this.noteId = id;
      this.isNew = false;
      this.saveIndicator = '已保存';
      setTimeout(() => { this.saveIndicator = ''; }, 2000);
    } catch (_) {
      this.saveIndicator = '保存失败';
    }
  }

  private async updateNote(): Promise<void> {
    if (!this.noteRepo || !this.note) {
      return;
    }
    this.note.title = this.editTitle || this.extractTitleFromContent();
    this.note.content = this.editContent;
    this.note.folderId = this.editFolderId.length > 0 ? this.editFolderId : undefined;
    this.note.tags = this.editTags.slice();
    this.note.contentPlain = this.editContent.replace(/[#*`>\-\[\]()!]/g, '').substring(0, 200);
    this.note.updatedAt = Date.now();
    try {
      await this.noteRepo.upsertNote(this.note);
      this.saveIndicator = '已保存';
      setTimeout(() => { this.saveIndicator = ''; }, 2000);
    } catch (_) {
      this.saveIndicator = '保存失败';
    }
  }

  private applyEditToNote(): void {
    if (!this.note) {
      return;
    }
    this.note.title = this.editTitle || this.extractTitleFromContent();
    this.note.content = this.editContent;
  }

  private extractTitleFromContent(): string {
    const lines: string[] = this.editContent.trim().split('\n');
    for (const line of lines) {
      const t: string = line.trim();
      if (t.startsWith('# ') && t.length > 2) {
        return t.substring(2).trim();
      }
      if (t.length > 0 && !t.startsWith('#')) {
        return t.substring(0, 50);
      }
    }
    return '无标题';
  }

  // ----- save progress -----

  private async saveProgress(): Promise<void> {
    if (!this.note || !this.noteRepo) {
      return;
    }
    const p: number = this.readingProgress;
    if (p !== this.note.readProgress) {
      this.note.readProgress = p;
      try {
        await this.noteRepo.upsertNote(this.note);
      } catch (e) {
        console.error('Failed to save progress:', e);
      }
    }
  }

  // ----- delete -----

  private confirmDelete(): void {
    const title: string = this.note?.title ?? '';
    promptAction.showDialog({
      title: '删除笔记',
      message: '确定要删除「' + title + '」吗？',
      buttons: [
        { text: '取消', color: '#999999' },
        { text: '删除', color: '#FF4757' }
      ]
    }).then((result) => {
      if (result.index === 1 && this.note && this.noteRepo) {
        this.noteRepo.deleteNote(this.note.id);
        promptAction.showToast({ message: '已删除' });
        router.back();
      }
    });
  }

  // ----- util -----

  private formatDate(timestamp: number): string {
    const d: Date = new Date(timestamp);
    return d.getFullYear() + '/' + (d.getMonth() + 1) + '/' + d.getDate();
  }
}
