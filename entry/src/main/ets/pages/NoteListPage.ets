import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { Note, NoteFolder, NoteType } from '../model/Note';
import { NoteRepository } from '../repository/NoteRepository';
import { PreferencesNoteRepository } from '../repository/PreferencesNoteRepository';
import { ImportProgress, ImportResult, NoteImportService } from '../service/NoteImportService';

interface FilterChip {
  label: string;
  value: NoteType | 'all';
}

class NoteDetailParams {
  noteId: string = '';
  isNew: string = '';
}

@Component
struct NoteListPage {
  @State notes: Note[] = [];
  @State folders: NoteFolder[] = [];
  @State searchKeyword: string = '';
  @State activeFilter: NoteType | 'all' = 'all';
  @State activeFolderId: string = '';
  @State isLoading: boolean = true;
  @State showFolderDialog: boolean = false;
  @State newFolderName: string = '';
  @State showNewFolderInput: boolean = false;
  @State showMoveFolder: boolean = false;
  @State moveTargetNoteId: string = '';
  @State showImportDialog: boolean = false;
  @State importProgressStage: string = 'reading';
  @State importProgressPercent: number = 0;
  @State importProgressMessage: string = '';
  @State isImporting: boolean = false;
  @State showSearchBar: boolean = false;
  @State showAddMenu: boolean = false;
  @State contextMenuNoteId: string = '';
  @State showDeleteConfirm: boolean = false;
  @State deleteTargetNoteId: string = '';
  private importService: NoteImportService | null = null;
  private noteRepo: NoteRepository | null = null;

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
      } catch (e) {
        console.error('Failed to initialize import service:', e);
        this.importService = null;
      }
    }
    return this.importService;
  }

  private readonly filters: FilterChip[] = [
    { label: '全部', value: 'all' },
    { label: '笔记', value: 'manual' },
    { label: '摘录', value: 'web_clip' },
    { label: '文档', value: 'import' }
  ];

  aboutToAppear(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      this.noteRepo = new PreferencesNoteRepository(context);
    } catch (e) {
      console.error('Failed to initialize NoteListPage:', e);
      this.noteRepo = null;
      promptAction.showToast({ message: '初始化失败,请重试' });
    }
    this.loadData();
  }

  onPageShow(): void {
    this.loadData();
  }

  private async loadData(): Promise<void> {
    if (!this.noteRepo) {
      this.isLoading = false;
      return;
    }
    try {
      const allNotes = await this.noteRepo.listNotes();
      const normalized: Note[] = [];
      for (const item of allNotes) {
        if (item !== null && item !== undefined) {
          normalized.push(this.normalizeNote(item as Note));
        }
      }
      this.notes = normalized;
    } catch (e) {
      this.notes = [];
    }
    try {
      if (this.noteRepo) {
        this.folders = await this.noteRepo.listFolders();
      }
    } catch (e) {
      this.folders = [];
    }
    this.isLoading = false;
  }

  private normalizeNote(note: Note): Note {
    const now = Date.now();
    const safeId = typeof note.id === 'string' && note.id.length > 0
      ? note.id
      : `note_invalid_${now}_${Math.random().toString(36).substring(2, 8)}`;
    const safeType: NoteType = note.type === 'manual' || note.type === 'web_clip' || note.type === 'import'
      ? note.type
      : 'manual';
    const safeTitle = typeof note.title === 'string' ? note.title : '';
    const safeContent = typeof note.content === 'string' ? note.content : '';
    const safeContentPlain = typeof note.contentPlain === 'string' ? note.contentPlain : '';
    const safeTags: string[] = [];
    if (Array.isArray(note.tags)) {
      for (const tag of note.tags) {
        if (typeof tag === 'string') {
          safeTags.push(tag);
        }
      }
    }

    return {
      id: safeId,
      type: safeType,
      title: safeTitle,
      content: safeContent,
      contentPlain: safeContentPlain,
      sourceUrl: typeof note.sourceUrl === 'string' ? note.sourceUrl : undefined,
      sourceTitle: typeof note.sourceTitle === 'string' ? note.sourceTitle : undefined,
      tags: safeTags,
      folderId: typeof note.folderId === 'string' ? note.folderId : undefined,
      isFavorite: note.isFavorite === true,
      importMeta: note.importMeta,
      readProgress: typeof note.readProgress === 'number' ? note.readProgress : 0,
      scrollPosition: typeof note.scrollPosition === 'string' ? note.scrollPosition : undefined,
      createdAt: typeof note.createdAt === 'number' ? note.createdAt : now,
      updatedAt: typeof note.updatedAt === 'number' ? note.updatedAt : now,
      deletedFlag: note.deletedFlag === true
    };
  }

  get filteredNotes(): Note[] {
    let result = this.notes;
    if (this.activeFilter !== 'all') {
      result = result.filter((n: Note) => n.type === this.activeFilter);
    }
    if (this.activeFolderId.length > 0) {
      result = result.filter((n: Note) => n.folderId === this.activeFolderId);
    }
    const kw = this.searchKeyword.trim().toLowerCase();
    if (kw.length > 0) {
      result = result.filter((n: Note) => {
        const title = typeof n?.title === 'string' ? n.title : '';
        const content = typeof n?.contentPlain === 'string' ? n.contentPlain : '';
        return title.toLowerCase().includes(kw) || content.toLowerCase().includes(kw);
      });
    }
    return result;
  }

  build() {
    Column() {
      Row() {
        Text('笔记')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')
          .layoutWeight(1)
        Button(this.showSearchBar ? '关闭搜索' : '搜索')
          .fontSize(12)
          .height(32)
          .onClick(() => {
            this.showSearchBar = !this.showSearchBar;
            if (!this.showSearchBar) {
              this.searchKeyword = '';
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })
      .backgroundColor('#FFFFFF')

      if (this.showSearchBar) {
        TextInput({ text: this.searchKeyword, placeholder: '搜索标题和内容' })
          .height(36)
          .width('100%')
          .backgroundColor('#F5F5F5')
          .borderRadius(8)
          .padding({ left: 12, right: 12 })
          .margin({ left: 16, right: 16, top: 8, bottom: 8 })
          .onChange((value: string) => {
            this.searchKeyword = value;
          })
      }

      if (this.isLoading) {
        Text('加载中...')
          .fontSize(14)
          .fontColor('#999999')
          .layoutWeight(1)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 40 })
      } else if (this.filteredNotes.length === 0) {
        Text('暂无笔记')
          .fontSize(14)
          .fontColor('#999999')
          .layoutWeight(1)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 40 })
      } else {
        List() {
          ForEach(this.filteredNotes, (note: Note) => {
            ListItem() {
              Row({ space: 10 }) {
                Column() {
                  Text(this.safeNoteTitle(note))
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#1A1A1A')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  if (this.safeNoteContentPlain(note).length > 0) {
                    Text(this.safeNoteContentPlain(note))
                      .fontSize(12)
                      .fontColor('#666666')
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                      .margin({ top: 4 })
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Button('删除')
                  .fontSize(12)
                  .height(28)
                  .backgroundColor('#FFF0F0')
                  .fontColor('#FF4757')
                  .onClick(() => {
                    this.deleteTargetNoteId = note.id;
                    this.showDeleteConfirm = true;
                  })
              }
              .width('100%')
              .padding(12)
              .backgroundColor('#FFFFFF')
              .borderRadius(10)
              .onClick(() => {
                const p = new NoteDetailParams();
                p.noteId = note.id;
                p.isNew = 'false';
                router.pushUrl({ url: 'pages/NoteDetailPage', params: p }).catch(() => {
                  promptAction.showToast({ message: '页面跳转失败' });
                });
              })
            }
          }, (item: Note, index: number) => {
            return typeof item.id === 'string' && item.id.length > 0 ? item.id : `note_fallback_${index}`;
          })
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 12, right: 12, top: 4, bottom: 70 })
      }

      if (!this.isLoading) {
        Row() {
          Button('新建')
            .width(56)
            .height(56)
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor('#007DFF')
            .borderRadius(28)
            .onClick(() => {
              const p = new NoteDetailParams();
              p.noteId = '';
              p.isNew = 'true';
              router.pushUrl({ url: 'pages/NoteDetailPage', params: p }).catch(() => {
                promptAction.showToast({ message: '页面跳转失败' });
              });
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .padding({ right: 16, bottom: 12 })
      }

      if (this.showDeleteConfirm) {
        this.DeleteConfirmOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F7FA')
  }

  // ======== Top Bar ========

  @Builder
  private TopBar() {
    Row() {
      Text('笔记')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor('#1A1A1A')
        .layoutWeight(1)

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
        if (!this.showSearchBar) {
          this.searchKeyword = '';
        }
      })
    }
    .width('100%')
    .height(52)
    .padding({ left: 20, right: 16 })
    .backgroundColor('#FFFFFF')
  }

  // ======== Search Bar ========

  @Builder
  private SearchBar() {
    Row({ space: 8 }) {
      TextInput({ text: this.searchKeyword, placeholder: '搜索笔记标题、内容...' })
        .height(36)
        .layoutWeight(1)
        .backgroundColor('#F5F5F5')
        .borderRadius(8)
        .placeholderFont({ size: 14 })
        .placeholderColor('#CCCCCC')
        .fontSize(14)
        .padding({ left: 12, right: 12 })
        .onChange((value: string) => {
          this.searchKeyword = value;
        })

      if (this.searchKeyword.length > 0) {
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
          this.searchKeyword = '';
        })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 4 })
  }

  // ======== Filter Chips ========

  @Builder
  private FilterBar() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.filters, (filter: FilterChip) => {
          Text(filter.label)
            .fontSize(13)
            .fontColor(this.activeFilter === filter.value ? '#FFFFFF' : '#666666')
            .fontWeight(this.activeFilter === filter.value ? FontWeight.Medium : FontWeight.Regular)
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .backgroundColor(this.activeFilter === filter.value ? '#007DFF' : '#F0F0F0')
            .borderRadius(16)
            .onClick(() => {
              this.activeFilter = filter.value;
            })
        })
      }
      .padding({ left: 16, right: 16, top: 8, bottom: 6 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .height(38)
  }

  // ======== Folder Bar ========

  @Builder
  private FolderBar() {
    Scroll() {
      Row({ space: 6 }) {
        // "全部" chip
        Text('全部')
          .fontSize(12)
          .fontColor(this.activeFolderId.length === 0 ? '#FFFFFF' : '#666666')
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .backgroundColor(this.activeFolderId.length === 0 ? '#5F27CD' : '#F0F0F0')
          .borderRadius(14)
          .onClick(() => {
            this.activeFolderId = '';
          })

        ForEach(this.folders, (folder: NoteFolder) => {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.folder'))
              .fontSize(11)
              .fontColor([this.activeFolderId === folder.id ? '#FFFFFF' : '#5F27CD'])
            Text(folder.name)
              .fontSize(12)
              .fontColor(this.activeFolderId === folder.id ? '#FFFFFF' : '#666666')
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.activeFolderId === folder.id ? '#5F27CD' : '#F5F0FA')
          .borderRadius(14)
          .onClick(() => {
            this.activeFolderId = this.activeFolderId === folder.id ? '' : folder.id;
          })
        })

        // Add folder button
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(12)
            .fontColor(['#5F27CD'])
        }
        .width(26)
        .height(26)
        .backgroundColor('#F5F0FA')
        .borderRadius(13)
        .onClick(() => {
          this.showNewFolderInput = true;
          this.newFolderName = '';
        })
      }
      .padding({ left: 16, right: 16, top: 2, bottom: 6 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .height(34)
  }

  // ======== Loading View ========

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

  // ======== Empty View ========

  @Builder
  private EmptyView() {
    Column() {
      SymbolGlyph($r('sys.symbol.doc_text'))
        .fontSize(48)
        .fontColor(['#E0E0E0'])
      Text(this.searchKeyword.length > 0 ? '没有找到匹配的笔记' : '还没有笔记')
        .fontSize(15)
        .fontColor('#999999')
        .margin({ top: 16 })
      if (this.searchKeyword.length === 0) {
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

  // ======== Note List ========

  @Builder
  private NoteListView() {
    List() {
      ForEach(this.filteredNotes, (note: Note) => {
        ListItem() {
          this.NoteCard(note)
        }
      }, (item: Note) => item.id)
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 12, right: 12, top: 4, bottom: 80 })
  }

  // ======== Note Card ========

  @Builder
  private NoteCard(note: Note) {
    Column() {
      Row() {
        // Type icon
        SymbolGlyph(this.noteTypeIcon(note.type))
          .fontSize(16)
          .fontColor([this.noteTypeColor(note.type)])

        Text(this.safeNoteTitle(note))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1A1A1A')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 8 })

        if (note.isFavorite) {
          SymbolGlyph($r('sys.symbol.star_fill'))
            .fontSize(14)
            .fontColor(['#FFC107'])
            .margin({ left: 4 })
        }
      }
      .width('100%')

      // Preview content
      if (this.safeNoteContentPlain(note).length > 0) {
        Text(this.safeNoteContentPlain(note))
          .fontSize(13)
          .fontColor('#666666')
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(18)
          .margin({ top: 6 })
      }

      // Bottom row: date + tags + folder + delete
      Row() {
        Column() {
          Row() {
            SymbolGlyph($r('sys.symbol.clock'))
              .fontSize(11)
              .fontColor(['#AAAAAA'])
            Text(this.formatDate(this.safeNoteCreatedAt(note)))
              .fontSize(11)
              .fontColor('#AAAAAA')
              .margin({ left: 4 })

            if (this.safeNoteFolderId(note).length > 0 && this.folderNameById(this.safeNoteFolderId(note)).length > 0) {
              SymbolGlyph($r('sys.symbol.folder'))
                .fontSize(11)
                .fontColor(['#AAAAAA'])
                .margin({ left: 12 })
              Text(this.folderNameById(this.safeNoteFolderId(note)))
                .fontSize(11)
                .fontColor('#AAAAAA')
                .margin({ left: 4 })
            }
          }
          .width('100%')

          // Tags
          if (this.safeNoteTags(note).length > 0) {
            Row({ space: 4 }) {
              Text(this.safeNoteTags(note)[0])
                .fontSize(10)
                .fontColor('#007DFF')
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor('#E8F4FF')
                .borderRadius(8)
              if (this.safeNoteTags(note).length > 1) {
                Text('+' + (this.safeNoteTags(note).length - 1))
                  .fontSize(10)
                  .fontColor('#999999')
              }
            }
            .width('100%')
            .margin({ top: 4 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // Delete button
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(13)
            .fontColor(['#CCCCCC'])
        }
        .width(28)
        .height(28)
        .backgroundColor('#FFFFFF')
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
      const p = new NoteDetailParams();
      p.noteId = note.id;
      p.isNew = 'false';
      try {
        router.pushUrl({
          url: 'pages/NoteDetailPage',
          params: p
        }).catch(() => {
          promptAction.showToast({ message: '页面跳转失败' });
        });
      } catch (_) {
        promptAction.showToast({ message: '页面跳转失败' });
      }
    })
  }

  // ======== FAB ========

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

  // ======== Add Menu Overlay ========

  @Builder
  private AddMenuOverlay() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.25)')
        .onClick(() => {
          this.showAddMenu = false;
        })

      Column() {
        Row() {
          this.AddMenuItem($r('sys.symbol.square_and_pencil'), '新建笔记', '#007DFF', () => {
            this.showAddMenu = false;
            const p = new NoteDetailParams();
            p.noteId = '';
            p.isNew = 'true';
            try {
              router.pushUrl({
                url: 'pages/NoteDetailPage',
                params: p
              }).catch(() => {
                promptAction.showToast({ message: '页面跳转失败' });
              });
            } catch (_) {
              promptAction.showToast({ message: '页面跳转失败' });
            }
          })
          this.AddMenuItem($r('sys.symbol.doc_text'), '导入TXT', '#5F27CD', () => {
            this.showAddMenu = false;
            this.pickAndImport('txt');
          })
          this.AddMenuItem($r('sys.symbol.doc_text'), '导入EPUB', '#2ED573', () => {
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
    .onClick(() => {
      action();
    })
  }

  // ======== Import Progress Overlay ========

  @Builder
  private ImportProgressOverlay() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.3)')

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
        color: 'rgba(0,0,0,0.1)',
        offsetX: 0,
        offsetY: 4
      })
    }
    .width('100%')
    .height('100%')
  }

  // ======== Folder Management Overlay ========

  @Builder
  private FolderManageOverlay() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.25)')
        .onClick(() => {
          this.showFolderDialog = false;
        })

      Column() {
        Row() {
          Text('管理文件夹')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1A1A1A')
            .layoutWeight(1)

          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(16)
              .fontColor(['#999999'])
          }
          .width(32)
          .height(32)
          .backgroundColor('#F5F5F5')
          .borderRadius(16)
          .onClick(() => {
            this.showFolderDialog = false;
          })
        }
        .width('100%')
        .padding({ bottom: 16 })

        if (this.folders.length === 0) {
          Text('暂无文件夹')
            .fontSize(14)
            .fontColor('#999999')
            .margin({ top: 20, bottom: 20 })
        } else {
          ForEach(this.folders, (folder: NoteFolder) => {
            Row() {
              SymbolGlyph($r('sys.symbol.folder'))
                .fontSize(16)
                .fontColor(['#5F27CD'])

              Text(folder.name)
                .fontSize(15)
                .fontColor('#1A1A1A')
                .layoutWeight(1)
                .margin({ left: 10 })

              Button({ type: ButtonType.Normal }) {
                SymbolGlyph($r('sys.symbol.trash'))
                  .fontSize(14)
                  .fontColor(['#FF4757'])
              }
              .width(32)
              .height(32)
              .backgroundColor('#FFF0F0')
              .borderRadius(16)
              .onClick(() => {
                this.deleteFolderWithConfirm(folder);
              })
            }
            .width('100%')
            .height(44)
            .padding({ left: 4 })
          })
        }

        Button('新建文件夹')
          .fontSize(14)
          .fontColor('#007DFF')
          .width('100%')
          .height(40)
          .backgroundColor('#F0F7FF')
          .borderRadius(8)
          .margin({ top: 12 })
          .onClick(() => {
            this.showFolderDialog = false;
            this.showNewFolderInput = true;
            this.newFolderName = '';
          })
      }
      .width('85%')
      .padding(20)
      .backgroundColor('#FFFFFF')
      .borderRadius(20)
      .shadow({
        radius: 16,
        color: 'rgba(0,0,0,0.1)',
        offsetX: 0,
        offsetY: 4
      })
      // Stack 默认居中；这里固定贴上方展示
      .position({ top: 80 })
    }
    .width('100%')
    .height('100%')
  }

  // ======== New Folder Overlay ========

  @Builder
  private NewFolderOverlay() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.25)')
        .onClick(() => {
          this.showNewFolderInput = false;
        })

      Column({ space: 16 }) {
        Text('新建文件夹')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1A1A1A')

        TextInput({ text: this.newFolderName, placeholder: '文件夹名称' })
          .height(40)
          .width('100%')
          .backgroundColor('#F5F5F5')
          .borderRadius(8)
          .placeholderFont({ size: 14 })
          .placeholderColor('#CCCCCC')
          .fontSize(14)
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.newFolderName = value;
          })
          .onSubmit(() => {
            this.createFolder();
          })

        Row({ space: 12 }) {
          Button('取消')
            .fontSize(14)
            .fontColor('#666666')
            .height(40)
            .layoutWeight(1)
            .backgroundColor('#F0F0F0')
            .borderRadius(8)
            .onClick(() => {
              this.showNewFolderInput = false;
            })

          Button('创建')
            .fontSize(14)
            .fontColor('#FFFFFF')
            .height(40)
            .layoutWeight(1)
            .backgroundColor(this.newFolderName.trim().length > 0 ? '#007DFF' : '#CCCCCC')
            .borderRadius(8)
            .enabled(this.newFolderName.trim().length > 0)
            .onClick(() => {
              this.createFolder();
            })
        }
        .width('100%')
      }
      .width(280)
      .padding(24)
      .backgroundColor('#FFFFFF')
      .borderRadius(20)
      .shadow({
        radius: 16,
        color: 'rgba(0,0,0,0.1)',
        offsetX: 0,
        offsetY: 4
      })
    }
    .width('100%')
    .height('100%')
  }

  // ======== Move Folder Overlay ========

  @Builder
  private MoveFolderOverlay() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.25)')
        .onClick(() => {
          this.showMoveFolder = false;
        })

      Column() {
        Row() {
          Text('移动到文件夹')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1A1A1A')
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ bottom: 16 })

        // "不分组" option
        Row() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(16)
            .fontColor(['#999999'])
          Text('不分组')
            .fontSize(15)
            .fontColor('#333333')
            .margin({ left: 10 })
        }
        .width('100%')
        .height(44)
        .padding({ left: 8 })
        .borderRadius(8)
        .onClick(() => {
          this.moveNoteToFolder(this.moveTargetNoteId, '');
        })

        ForEach(this.folders, (folder: NoteFolder) => {
          Row() {
            SymbolGlyph($r('sys.symbol.folder'))
              .fontSize(16)
              .fontColor(['#5F27CD'])
            Text(folder.name)
              .fontSize(15)
              .fontColor('#333333')
              .margin({ left: 10 })
              .layoutWeight(1)
            if (folder.id === this.noteFolderId(this.moveTargetNoteId)) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(16)
                .fontColor(['#007DFF'])
            }
          }
          .width('100%')
          .height(44)
          .padding({ left: 8 })
          .borderRadius(8)
          .onClick(() => {
            this.moveNoteToFolder(this.moveTargetNoteId, folder.id);
          })
        })
      }
      .width('80%')
      .padding(20)
      .backgroundColor('#FFFFFF')
      .borderRadius(20)
      .shadow({
        radius: 16,
        color: 'rgba(0,0,0,0.1)',
        offsetX: 0,
        offsetY: 4
      })
    }
    .width('100%')
    .height('100%')
  }

  // ======== Delete Confirm Overlay ========

  @Builder
  private DeleteConfirmOverlay() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.25)')

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
        color: 'rgba(0,0,0,0.1)',
        offsetX: 0,
        offsetY: 4
      })
    }
    .width('100%')
    .height('100%')
  }

  // ======== Helper Methods ========

  private noteTypeIcon(type: NoteType): Resource {
    if (type === 'manual') return $r('sys.symbol.square_and_pencil');
    if (type === 'web_clip') return $r('sys.symbol.eye');
    return $r('sys.symbol.doc_text');
  }

  private noteTypeColor(type: NoteType): string {
    if (type === 'manual') return '#007DFF';
    if (type === 'web_clip') return '#2ED573';
    return '#5F27CD';
  }

  private safeNoteTitle(note: Note): string {
    return typeof note.title === 'string' && note.title.length > 0 ? note.title : '无标题';
  }

  private safeNoteContentPlain(note: Note): string {
    return typeof note.contentPlain === 'string' ? note.contentPlain : '';
  }

  private safeNoteTags(note: Note): string[] {
    return Array.isArray(note.tags) ? note.tags : [];
  }

  private safeNoteCreatedAt(note: Note): number {
    return typeof note.createdAt === 'number' ? note.createdAt : Date.now();
  }

  private safeNoteFolderId(note: Note): string {
    return typeof note.folderId === 'string' ? note.folderId : '';
  }

  private formatDate(timestamp: number): string {
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

  private folderNameById(folderId: string): string {
    for (const f of this.folders) {
      if (f.id === folderId) return f.name;
    }
    return '';
  }

  private noteFolderId(noteId: string): string {
    for (const n of this.notes) {
      if (n.id === noteId) return n.folderId ?? '';
    }
    return '';
  }

  private async createFolder(): Promise<void> {
    const name = this.newFolderName.trim();
    if (name.length === 0 || !this.noteRepo) return;
    const now = Date.now();
    const folder: NoteFolder = {
      id: 'folder_' + now + '_' + Math.random().toString(36).substring(2, 6),
      name: name,
      updatedAt: now
    };
    try {
      await this.noteRepo.upsertFolder(folder);
      this.showNewFolderInput = false;
      this.newFolderName = '';
      this.loadData();
      promptAction.showToast({ message: '文件夹已创建' });
    } catch (e) {
      promptAction.showToast({ message: '创建失败' });
    }
  }

  private async deleteFolderWithConfirm(folder: NoteFolder): Promise<void> {
    try {
      if (!this.noteRepo) return;
      await this.noteRepo.deleteFolder(folder.id);
      this.loadData();
      promptAction.showToast({ message: '已删除文件夹' });
    } catch (e) {
      promptAction.showToast({ message: '删除失败' });
    }
  }

  private async moveNoteToFolder(noteId: string, folderId: string): Promise<void> {
    if (!this.noteRepo) return;
    try {
      const note = await this.noteRepo.getNoteById(noteId);
      if (note) {
        note.folderId = folderId.length > 0 ? folderId : undefined;
        await this.noteRepo.upsertNote(note);
        this.showMoveFolder = false;
        this.loadData();
        promptAction.showToast({ message: folderId.length > 0 ? '已移动到文件夹' : '已取消分组' });
      }
    } catch (e) {
      promptAction.showToast({ message: '移动失败' });
    }
  }

  private async confirmDeleteNote(): Promise<void> {
    if (!this.noteRepo) return;
    try {
      await this.noteRepo.deleteNote(this.deleteTargetNoteId);
      this.showDeleteConfirm = false;
      this.loadData();
      promptAction.showToast({ message: '已删除' });
    } catch (e) {
      promptAction.showToast({ message: '删除失败' });
    }
  }

  private async pickAndImport(fileType: 'txt' | 'epub'): Promise<void> {
    const importService = this.getImportService();
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const results: string[] = await documentPicker.select();
      if (results.length === 0 || !importService || !this.noteRepo) return;

      const uri: string = results[0];
      this.showImportDialog = true;
      this.isImporting = true;

      const fileInfo = await importService.getFileInfo(uri);
      let result: ImportResult;
      if (fileType === 'epub') {
        result = await importService.importEpub(uri, fileInfo.name);
      } else {
        result = await importService.importTxt(uri, fileInfo.name);
      }

      await this.noteRepo.upsertNote(result.note);
      this.showImportDialog = false;
      this.isImporting = false;
      promptAction.showToast({ message: '导入成功' });
      this.loadData();

      // Navigate to the imported note
      const p = new NoteDetailParams();
      p.noteId = result.note.id;
      p.isNew = 'false';
      router.pushUrl({
        url: 'pages/NoteDetailPage',
        params: p
      }).catch(() => {
        promptAction.showToast({ message: '页面跳转失败' });
      });
    } catch (e) {
      this.showImportDialog = false;
      this.isImporting = false;
      const errMsg = (e as Error).message || String(e);
      promptAction.showToast({ message: '导入失败: ' + errMsg });
    }
  }
}
