import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { Note, NoteFolder } from '../model/Note';
import { NoteRepository } from '../repository/NoteRepository';
import { NOTE_FOLDER_IDS, PreferencesNoteRepository } from '../repository/PreferencesNoteRepository';

interface DialogResult {
  index: number;
}

class FolderManagerPageParams {
  mode: string = '';
  selectedFolderId: string = '';
  noteId: string = '';
}

interface NoteListRouteParams {
  folderId: string;
}

@Entry
@Component
struct NoteFolderManagerPage {
  @State folders: NoteFolder[] = [];
  @State selectedFolderId: string = '';
  @State mode: 'select' | 'move' = 'select';
  @State moveNoteId: string = '';
  @State editingFolderId: string = '';
  @State draftName: string = '';
  @State creatingParentId: string = '';
  @State draftNewName: string = '';
  private noteRepo: NoteRepository | null = null;

  aboutToAppear(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      this.noteRepo = new PreferencesNoteRepository(context);
      const params = router.getParams() as FolderManagerPageParams;
      if (params !== undefined && params !== null) {
        this.selectedFolderId = typeof params.selectedFolderId === 'string' ? params.selectedFolderId : '';
        this.moveNoteId = typeof params.noteId === 'string' ? params.noteId : '';
        this.mode = params.mode === 'move' ? 'move' : 'select';
      }
      this.loadFolders();
    } catch (_) {
      promptAction.showToast({ message: '初始化失败' });
    }
  }

  private async loadFolders(): Promise<void> {
    if (!this.noteRepo) return;
    try {
      const list = await this.noteRepo.listFolders();
      // New array + stable keys that include name so rename refreshes ForEach children.
      this.folders = list.map((f: NoteFolder) => this.copyFolder(f));
    } catch (_) {
      this.folders = [];
    }
  }

  private copyFolder(f: NoteFolder): NoteFolder {
    return {
      id: f.id,
      name: f.name,
      parentId: f.parentId,
      icon: f.icon,
      color: f.color,
      updatedAt: f.updatedAt
    };
  }

  /** ForEach key must change when folder display fields change, or Text may stay stale. */
  private folderRowKey(f: NoteFolder): string {
    return `${f.id}|${f.updatedAt}|${f.name}`;
  }

  private childrenOf(parentId: string): NoteFolder[] {
    const pid = parentId.length === 0 ? undefined : parentId;
    return this.folders
      .filter((f: NoteFolder) => (f.parentId ?? undefined) === pid)
      .sort((a: NoteFolder, b: NoteFolder) => a.name.localeCompare(b.name));
  }

  private folderColor(folderId: string): string {
    const folder = this.folders.find((f: NoteFolder) => f.id === folderId);
    if (folder?.color) return folder.color;
    if (folderId === NOTE_FOLDER_IDS.root) return '#5F27CD';
    if (folderId === NOTE_FOLDER_IDS.personal) return '#007DFF';
    if (folderId === NOTE_FOLDER_IDS.study) return '#2ED573';
    if (folderId === NOTE_FOLDER_IDS.work) return '#FF6B6B';
    if (folderId === NOTE_FOLDER_IDS.life) return '#FFC107';
    return '#5F27CD';
  }

  private canDelete(folderId: string): boolean {
    return folderId !== NOTE_FOLDER_IDS.root;
  }

  private async renameFolder(folderId: string, name: string): Promise<void> {
    if (!this.noteRepo) return;
    const next = name.trim();
    if (next.length === 0) {
      promptAction.showToast({ message: '名称不能为空' });
      return;
    }
    const existing = this.folders.find((f: NoteFolder) => f.id === folderId);
    if (!existing) return;
    const now = Date.now();
    await this.noteRepo.upsertFolder({
      id: existing.id,
      name: next,
      parentId: existing.parentId,
      icon: existing.icon,
      color: existing.color,
      updatedAt: now
    });
    // Optimistic UI: row Text updates immediately (repo reload alone may not refresh ForEach subtree).
    const idx = this.folders.findIndex((x: NoteFolder) => x.id === folderId);
    if (idx >= 0) {
      const merged: NoteFolder = {
        id: existing.id,
        name: next,
        parentId: existing.parentId,
        icon: existing.icon,
        color: existing.color,
        updatedAt: now
      };
      const nextList = this.folders.map((x: NoteFolder) => this.copyFolder(x));
      nextList[idx] = merged;
      this.folders = nextList;
    }
    this.editingFolderId = '';
    this.draftName = '';
    await this.loadFolders();
  }

  private async createFolder(parentId: string, name: string): Promise<void> {
    if (!this.noteRepo) return;
    const next = name.trim();
    if (next.length === 0) {
      promptAction.showToast({ message: '名称不能为空' });
      return;
    }
    const id = `${Date.now()}_${Math.random().toString(36).substring(2, 8)}`;
    await this.noteRepo.upsertFolder({
      id,
      name: next,
      parentId: parentId.length > 0 ? parentId : undefined,
      updatedAt: Date.now()
    });
    this.creatingParentId = '';
    this.draftNewName = '';
    await this.loadFolders();
  }

  private async deleteFolder(folderId: string): Promise<void> {
    if (!this.noteRepo) return;
    if (!this.canDelete(folderId)) {
      promptAction.showToast({ message: '默认目录不可删除' });
      return;
    }
    try {
      await this.noteRepo.deleteFolder(folderId);
      if (this.selectedFolderId === folderId) this.selectedFolderId = '';
      await this.loadFolders();
    } catch (_) {
      promptAction.showToast({ message: '删除失败' });
    }
  }

  private async onSelect(folderId: string): Promise<void> {
    if (!this.noteRepo) return;
    this.selectedFolderId = folderId === NOTE_FOLDER_IDS.root ? '' : folderId;
    if (this.mode === 'move' && this.moveNoteId.length > 0) {
      const note = await this.noteRepo.getNoteById(this.moveNoteId);
      if (note) {
        const n = note as Note;
        const toSave: Note = {
          id: n.id,
          type: n.type,
          title: n.title,
          content: n.content,
          contentPlain: n.contentPlain,
          sourceUrl: n.sourceUrl,
          sourceTitle: n.sourceTitle,
          tags: Array.isArray(n.tags) ? n.tags : [],
          folderId: this.selectedFolderId.length > 0 ? this.selectedFolderId : undefined,
          isFavorite: n.isFavorite === true,
          importMeta: n.importMeta,
          readProgress: typeof n.readProgress === 'number' ? n.readProgress : 0,
          scrollPosition: n.scrollPosition,
          createdAt: typeof n.createdAt === 'number' ? n.createdAt : Date.now(),
          updatedAt: Date.now(),
          deletedFlag: n.deletedFlag === true
        };
        await this.noteRepo.upsertNote(toSave);
      }
    }
    const p: NoteListRouteParams = { folderId: this.selectedFolderId };
    router.replaceUrl({ url: 'pages/NoteListPageSafe', params: p }).catch(() => {
      router.back();
    });
  }

  @Builder
  private FolderNode(parentId: string, level: number) {
    ForEach(this.childrenOf(parentId), (f: NoteFolder) => {
      Column({ space: 4 }) {
        // Folder row
        Row({ space: 8 }) {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.folder'))
              .fontSize(16)
              .fontColor([this.folderColor(f.id)])
            Text(f.name)
              .fontSize(14)
              .fontColor(this.selectedFolderId === f.id ? '#007DFF' : '#1A1A1A')
              .fontWeight(this.selectedFolderId === f.id ? FontWeight.Medium : FontWeight.Regular)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .onClick(() => {
            this.onSelect(f.id);
          })

          if (this.editingFolderId !== f.id) {
            Row({ space: 4 }) {
              Button({ type: ButtonType.Normal }) {
                SymbolGlyph($r('sys.symbol.square_and_pencil'))
                  .fontSize(12)
                  .fontColor(['#999999'])
              }
              .width(26)
              .height(26)
              .backgroundColor('#F0F0F0')
              .borderRadius(6)
              .onClick(() => {
                this.editingFolderId = f.id;
                this.draftName = f.name;
              })

              Button({ type: ButtonType.Normal }) {
                SymbolGlyph($r('sys.symbol.plus'))
                  .fontSize(12)
                  .fontColor(['#007DFF'])
              }
              .width(26)
              .height(26)
              .backgroundColor('#E8F4FF')
              .borderRadius(6)
              .onClick(() => {
                this.creatingParentId = f.id;
                this.draftNewName = '';
              })

              if (this.canDelete(f.id)) {
                Button({ type: ButtonType.Normal }) {
                  SymbolGlyph($r('sys.symbol.trash'))
                    .fontSize(12)
                    .fontColor(['#FF4757'])
                }
                .width(26)
                .height(26)
                .backgroundColor('#FFF0F0')
                .borderRadius(6)
                .onClick(() => {
                  promptAction.showDialog({
                    title: '确认删除',
                    message: '删除后，目录内笔记会迁移到上级目录。',
                    buttons: [
                      { text: '取消', color: '#666666' },
                      { text: '删除', color: '#FF4757' }
                    ]
                  }).then((res: DialogResult) => {
                    if (res && res.index === 1) this.deleteFolder(f.id);
                  }).catch(() => {});
                })
              }
            }
          }
        }
        .width('100%')
        .padding({ left: 16 + level * 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.selectedFolderId === f.id ? '#F0F7FF' : 'transparent')
        .borderRadius(8)

        // Inline rename
        if (this.editingFolderId === f.id) {
          Row({ space: 8 }) {
            TextInput({ text: this.draftName, placeholder: '目录名称' })
              .layoutWeight(1)
              .height(34)
              .fontSize(12)
              .backgroundColor('#F2F3F5')
              .borderRadius(8)
              .padding({ left: 10, right: 10 })
              .onChange((v: string) => { this.draftName = v; })
            Button('保存')
              .height(28)
              .fontSize(11)
              .fontColor('#FFFFFF')
              .backgroundColor('#007DFF')
              .borderRadius(6)
              .padding({ left: 10, right: 10 })
              .onClick(() => this.renameFolder(f.id, this.draftName))
            Button('取消')
              .height(28)
              .fontSize(11)
              .fontColor('#666666')
              .backgroundColor('#F0F0F0')
              .borderRadius(6)
              .padding({ left: 10, right: 10 })
              .onClick(() => {
                this.editingFolderId = '';
                this.draftName = '';
              })
          }
          .width('100%')
          .padding({ left: 16 + level * 16, right: 16, bottom: 6 })
        }

        // Inline create
        if (this.creatingParentId === f.id) {
          Row({ space: 8 }) {
            TextInput({ text: this.draftNewName, placeholder: '新目录名称' })
              .layoutWeight(1)
              .height(34)
              .fontSize(12)
              .backgroundColor('#F2F3F5')
              .borderRadius(8)
              .padding({ left: 10, right: 10 })
              .onChange((v: string) => { this.draftNewName = v; })
            Button('创建')
              .height(28)
              .fontSize(11)
              .fontColor('#FFFFFF')
              .backgroundColor('#007DFF')
              .borderRadius(6)
              .padding({ left: 10, right: 10 })
              .onClick(() => this.createFolder(f.id, this.draftNewName))
            Button('取消')
              .height(28)
              .fontSize(11)
              .fontColor('#666666')
              .backgroundColor('#F0F0F0')
              .borderRadius(6)
              .padding({ left: 10, right: 10 })
              .onClick(() => {
                this.creatingParentId = '';
                this.draftNewName = '';
              })
          }
          .width('100%')
          .padding({ left: 16 + level * 16, right: 16, bottom: 6 })
        }

        this.FolderNode(f.id, level + 1)
      }
      .width('100%')
    }, (f: NoteFolder) => this.folderRowKey(f))
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(18)
            .fontColor(['#666666'])
        }
        .width(36)
        .height(36)
        .backgroundColor('#F0F0F0')
        .borderRadius(18)
        .onClick(() => router.back())

        Text(this.mode === 'move' ? '移动笔记到...' : '选择目录')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1A1A1A')
          .layoutWeight(1)
          .margin({ left: 4 })

        // 目录管理页不展示“全部”（只在浏览页有），这里仅提供创建顶层目录入口
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(16)
            .fontColor(['#007DFF'])
        }
        .width(36)
        .height(36)
        .backgroundColor('#E8F4FF')
        .borderRadius(18)
        .onClick(() => {
          this.creatingParentId = NOTE_FOLDER_IDS.root;
          this.draftNewName = '';
        })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 8 })

      Scroll() {
        Column() {
          // 顶层目录创建输入（root 被隐藏后需要单独入口）
          if (this.creatingParentId === NOTE_FOLDER_IDS.root) {
            Row({ space: 8 }) {
              TextInput({ text: this.draftNewName, placeholder: '新目录名称' })
                .layoutWeight(1)
                .height(34)
                .fontSize(12)
                .backgroundColor('#F2F3F5')
                .borderRadius(8)
                .padding({ left: 10, right: 10 })
                .onChange((v: string) => { this.draftNewName = v; })
              Button('创建')
                .height(28)
                .fontSize(11)
                .fontColor('#FFFFFF')
                .backgroundColor('#007DFF')
                .borderRadius(6)
                .padding({ left: 10, right: 10 })
                .onClick(() => this.createFolder(NOTE_FOLDER_IDS.root, this.draftNewName))
              Button('取消')
                .height(28)
                .fontSize(11)
                .fontColor('#666666')
                .backgroundColor('#F0F0F0')
                .borderRadius(6)
                .padding({ left: 10, right: 10 })
                .onClick(() => {
                  this.creatingParentId = '';
                  this.draftNewName = '';
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 6 })
          }

          // 从 root 的子目录开始渲染，隐藏 root（“全部”）
          this.FolderNode(NOTE_FOLDER_IDS.root, 0)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Start)
  }
}
