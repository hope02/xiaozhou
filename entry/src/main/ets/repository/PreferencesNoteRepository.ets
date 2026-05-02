import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { Note, NoteFolder, NoteSnapshot, NoteType } from '../model/Note';
import { NoteRepository } from './NoteRepository';

const STORE_NAME: string = 'xiaozhou_notes';
const SNAPSHOT_KEY: string = 'note_snapshot';
const SCHEMA_VERSION: number = 1;

/** ArkTS 严格模式下用于 flush 兼容的显式类型（避免 any/unknown 与 call signature） */
class ThenableVoid {
  then(_onFulfilled: () => void, _onRejected?: (e: Object) => void): void {
  }
}

interface PreferencesFlushCompat {
  flushSync?: () => void;
  /**
   * SDK 形态不一：可能是 flush(): Promise-like，也可能是 flush(cb)
   * 这里用 Function 做最小约束，避免 call signature interface 触发 arkts-no-call-signatures。
   */
  flush?: Function;
}

export class NOTE_FOLDER_IDS {
  static readonly root: string = 'note_folder_root';
  static readonly personal: string = 'note_folder_personal';
  static readonly study: string = 'note_folder_study';
  static readonly work: string = 'note_folder_work';
  static readonly life: string = 'note_folder_life';
}

interface EnsureDefaultFoldersResult {
  snapshot: NoteSnapshot;
  changed: boolean;
}

export class PreferencesNoteRepository implements NoteRepository {
  private readonly context: common.UIAbilityContext;
  private dataPreferences: preferences.Preferences | null = null;
  private readonly fallbackSnapshot: NoteSnapshot = {
    schemaVersion: SCHEMA_VERSION,
    notes: [],
    folders: []
  };

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async getSnapshot(): Promise<NoteSnapshot> {
    this.ensureStore();
    const snapshot = this.readSnapshot();
    const ensured = this.ensureDefaultFolders(snapshot);
    if (ensured.changed) {
      await this.writeSnapshot(ensured.snapshot);
    }
    return ensured.snapshot;
  }

  async setSnapshot(snapshot: NoteSnapshot): Promise<void> {
    this.ensureStore();
    await this.writeSnapshot(snapshot);
  }

  async listNotes(type?: NoteType, includeDeleted: boolean = false): Promise<Note[]> {
    const snapshot = await this.getSnapshot();
    let result = snapshot.notes;
    if (!includeDeleted) {
      result = result.filter((item: Note) => !item.deletedFlag);
    }
    if (type !== undefined) {
      result = result.filter((item: Note) => item.type === type);
    }
    return result;
  }

  async listFolders(): Promise<NoteFolder[]> {
    const snapshot = await this.getSnapshot();
    return snapshot.folders.slice();
  }

  async getNoteById(id: string): Promise<Note | null> {
    const snapshot = await this.getSnapshot();
    const found = snapshot.notes.find((item: Note) => item.id === id);
    return found ?? null;
  }

  async upsertNote(note: Note): Promise<void> {
    this.ensureStore();
    const snapshot = this.readSnapshot();
    const index = snapshot.notes.findIndex((item: Note) => item.id === note.id);
    if (index < 0) {
      snapshot.notes.push({
        id: note.id,
        type: note.type,
        title: note.title,
        content: note.content,
        contentPlain: note.contentPlain,
        sourceUrl: note.sourceUrl,
        sourceTitle: note.sourceTitle,
        tags: note.tags ?? [],
        folderId: note.folderId,
        isFavorite: note.isFavorite ?? false,
        importMeta: note.importMeta,
        readProgress: note.readProgress ?? 0,
        scrollPosition: note.scrollPosition,
        createdAt: note.createdAt ?? Date.now(),
        updatedAt: Date.now(),
        deletedFlag: note.deletedFlag ?? false
      });
    } else {
      const current = snapshot.notes[index];
      current.title = note.title;
      current.content = note.content;
      current.contentPlain = note.contentPlain;
      current.sourceUrl = note.sourceUrl;
      current.sourceTitle = note.sourceTitle;
      current.tags = note.tags ?? [];
      current.folderId = note.folderId;
      current.isFavorite = note.isFavorite ?? current.isFavorite;
      current.importMeta = note.importMeta;
      current.readProgress = note.readProgress ?? current.readProgress;
      current.scrollPosition = note.scrollPosition;
      current.deletedFlag = note.deletedFlag ?? false;
      current.updatedAt = Date.now();
    }
    await this.writeSnapshot(snapshot);
  }

  async deleteNote(id: string): Promise<void> {
    this.ensureStore();
    const snapshot = this.readSnapshot();
    const index = snapshot.notes.findIndex((item: Note) => item.id === id);
    if (index < 0) {
      return;
    }
    snapshot.notes[index].deletedFlag = true;
    snapshot.notes[index].updatedAt = Date.now();
    await this.writeSnapshot(snapshot);
  }

  async hardDeleteNote(id: string): Promise<void> {
    this.ensureStore();
    const snapshot = this.readSnapshot();
    const index = snapshot.notes.findIndex((item: Note) => item.id === id);
    if (index < 0) {
      return;
    }
    snapshot.notes.splice(index, 1);
    await this.writeSnapshot(snapshot);
  }

  async upsertFolder(folder: NoteFolder): Promise<void> {
    this.ensureStore();
    const snapshot = this.readSnapshot();
    const ensured = this.ensureDefaultFolders(snapshot);
    const s = ensured.snapshot;
    const index = s.folders.findIndex((item: NoteFolder) => item.id === folder.id);
    if (index < 0) {
      s.folders.push({
        id: folder.id,
        name: folder.name,
        parentId: folder.parentId,
        icon: folder.icon,
        color: folder.color,
        updatedAt: Date.now()
      });
    } else {
      s.folders[index].name = folder.name;
      s.folders[index].parentId = folder.parentId;
      s.folders[index].icon = folder.icon;
      s.folders[index].color = folder.color;
      s.folders[index].updatedAt = Date.now();
    }
    await this.writeSnapshot(s);
  }

  async deleteFolder(id: string): Promise<void> {
    this.ensureStore();
    // Root folder is structural ("全部") and should always exist.
    if (id === NOTE_FOLDER_IDS.root) {
      return;
    }
    const snapshot = this.readSnapshot();
    const ensured = this.ensureDefaultFolders(snapshot);
    const s = ensured.snapshot;
    const index = s.folders.findIndex((item: NoteFolder) => item.id === id);
    if (index < 0) {
      return;
    }
    const parentId = s.folders[index].parentId;
    s.folders.splice(index, 1);
    // Re-parent child folders to the deleted folder's parent
    for (const f of s.folders) {
      if (f.parentId === id) {
        f.parentId = parentId;
        f.updatedAt = Date.now();
      }
    }
    for (const note of s.notes) {
      if (note.folderId === id) {
        note.folderId = parentId;
        note.updatedAt = Date.now();
      }
    }
    await this.writeSnapshot(s);
  }

  async searchNotes(keyword: string): Promise<Note[]> {
    if (keyword.trim().length === 0) {
      return this.listNotes();
    }
    const snapshot = await this.getSnapshot();
    const lower = keyword.toLowerCase();
    return snapshot.notes.filter((item: Note) => {
      if (item.deletedFlag) {
        return false;
      }
      if (item.title.toLowerCase().includes(lower)) {
        return true;
      }
      if (item.contentPlain?.toLowerCase().includes(lower)) {
        return true;
      }
      if (item.tags.some((tag: string) => tag.toLowerCase().includes(lower))) {
        return true;
      }
      return false;
    });
  }

  private ensureStore(): void {
    if (this.dataPreferences !== null) {
      return;
    }
    try {
      this.dataPreferences = preferences.getPreferencesSync(this.context, { name: STORE_NAME });
    } catch (e) {
      console.error('Failed to initialize preferences store:', e);
      throw new Error(`Failed to initialize preferences store: ${e}`);
    }
  }

  /**
   * Coerce legacy / partial JSON into a valid Note instead of dropping the row.
   * Strict filtering caused silent data loss on every upsert (read → drop → write).
   */
  private normalizeStoredNote(raw: Note): Note | null {
    if (raw === null || raw === undefined) {
      return null;
    }
    const id = typeof raw.id === 'string' && raw.id.length > 0 ? raw.id : '';
    if (id.length === 0) {
      return null;
    }
    const now = Date.now();
    const type: NoteType =
      raw.type === 'manual' || raw.type === 'web_clip' || raw.type === 'import' ? raw.type : 'manual';
    const tags = Array.isArray(raw.tags) ? raw.tags.filter((t: string) => typeof t === 'string') : [];
    return {
      id,
      type,
      title: typeof raw.title === 'string' ? raw.title : '',
      content: typeof raw.content === 'string' ? raw.content : '',
      contentPlain: typeof raw.contentPlain === 'string' ? raw.contentPlain : undefined,
      sourceUrl: typeof raw.sourceUrl === 'string' ? raw.sourceUrl : undefined,
      sourceTitle: typeof raw.sourceTitle === 'string' ? raw.sourceTitle : undefined,
      tags,
      folderId: typeof raw.folderId === 'string' && raw.folderId.length > 0 ? raw.folderId : undefined,
      isFavorite: raw.isFavorite === true,
      importMeta: raw.importMeta,
      readProgress: typeof raw.readProgress === 'number' ? raw.readProgress : 0,
      scrollPosition: typeof raw.scrollPosition === 'string' ? raw.scrollPosition : undefined,
      createdAt: typeof raw.createdAt === 'number' ? raw.createdAt : now,
      updatedAt: typeof raw.updatedAt === 'number' ? raw.updatedAt : now,
      deletedFlag: raw.deletedFlag === true
    };
  }

  private normalizeStoredFolder(raw: NoteFolder): NoteFolder | null {
    if (raw === null || raw === undefined) {
      return null;
    }
    const id = typeof raw.id === 'string' && raw.id.length > 0 ? raw.id : '';
    if (id.length === 0) {
      return null;
    }
    const now = Date.now();
    return {
      id,
      name: typeof raw.name === 'string' ? raw.name : '未命名',
      parentId: typeof raw.parentId === 'string' ? raw.parentId : undefined,
      icon: typeof raw.icon === 'string' ? raw.icon : undefined,
      color: typeof raw.color === 'string' ? raw.color : undefined,
      updatedAt: typeof raw.updatedAt === 'number' ? raw.updatedAt : now
    };
  }

  private readSnapshot(): NoteSnapshot {
    if (this.dataPreferences === null) {
      return {
        schemaVersion: SCHEMA_VERSION,
        notes: [],
        folders: []
      };
    }
    // Some SDK/runtime variants may return undefined even when a default is provided.
    // Coerce to string to avoid `cannot read property 'length' of undefined`.
    const raw = this.dataPreferences.getSync(SNAPSHOT_KEY, '') as string | undefined | null;
    const rawValue: string = typeof raw === 'string' ? raw : '';
    if (rawValue.length === 0) {
      return {
        schemaVersion: SCHEMA_VERSION,
        notes: [],
        folders: []
      };
    }

    try {
      const parsed = JSON.parse(rawValue) as NoteSnapshot;
      if (!Array.isArray(parsed.notes) || !Array.isArray(parsed.folders)) {
        return this.fallbackSnapshot;
      }

      const normalizedNotes: Note[] = [];
      for (const item of parsed.notes) {
        const n = this.normalizeStoredNote(item as Note);
        if (n !== null) {
          normalizedNotes.push(n);
        }
      }

      const normalizedFolders: NoteFolder[] = [];
      for (const item of parsed.folders) {
        const f = this.normalizeStoredFolder(item as NoteFolder);
        if (f !== null) {
          normalizedFolders.push(f);
        }
      }

      return {
        schemaVersion: parsed.schemaVersion ?? SCHEMA_VERSION,
        notes: normalizedNotes,
        folders: normalizedFolders
      };
    } catch (_) {
      return this.fallbackSnapshot;
    }
  }

  private buildFolder(id: string, name: string, parentId: string | undefined, updatedAt: number): NoteFolder {
    return {
      id,
      name,
      parentId,
      updatedAt
    };
  }

  private ensureDefaultFolders(snapshot: NoteSnapshot): EnsureDefaultFoldersResult {
    // Ensure structural root exists, but keep user-created folders.
    const folders: NoteFolder[] = Array.isArray(snapshot.folders) ? snapshot.folders.slice() : [];
    const now = Date.now();
    const byId = new Map<string, NoteFolder>();
    for (const f of folders) {
      if (f && typeof f.id === 'string') {
        byId.set(f.id, f);
      }
    }

    let changed = false;
    const upsert = (folder: NoteFolder) => {
      const existing = byId.get(folder.id);
      if (!existing) {
        folders.push(folder);
        byId.set(folder.id, folder);
        changed = true;
        return;
      }
      // Ensure structural fields exist (parentId) while preserving user edits (name/icon/color)
      if (existing.parentId !== folder.parentId) {
        existing.parentId = folder.parentId;
        existing.updatedAt = now;
        changed = true;
      }
    };

    upsert(this.buildFolder(NOTE_FOLDER_IDS.root, '全部', undefined, now));

    // Fix folder parent references (missing parent -> root)
    for (const f of folders) {
      if (!f) continue;
      if (typeof f.parentId === 'string' && f.parentId.length > 0 && !byId.has(f.parentId)) {
        f.parentId = NOTE_FOLDER_IDS.root;
        f.updatedAt = now;
        changed = true;
      }
    }

    // Migrate notes whose folderId no longer exists -> root
    for (const n of snapshot.notes ?? []) {
      if (!n) continue;
      if (typeof n.folderId === 'string' && n.folderId.length > 0 && !byId.has(n.folderId)) {
        n.folderId = undefined;
        n.updatedAt = now;
        changed = true;
      }
    }

    if (!changed) {
      const result: EnsureDefaultFoldersResult = { snapshot: snapshot, changed: false };
      return result;
    }
    const ensuredSnapshot: NoteSnapshot = {
      schemaVersion: snapshot.schemaVersion ?? SCHEMA_VERSION,
      notes: snapshot.notes ?? [],
      folders: folders
    };
    const result: EnsureDefaultFoldersResult = { snapshot: ensuredSnapshot, changed: true };
    return result;
  }

  /**
   * putSync 只写入 Preferences 内存；必须等待 flush 落盘后再返回，
   * 否则立刻 router.back() / 切换页面时另一处 getPreferencesSync 可能仍读到旧文件，表现为「已保存但列表没有」。
   */
  private async writeSnapshot(snapshot: NoteSnapshot): Promise<void> {
    if (this.dataPreferences === null) {
      throw new Error('笔记存储未初始化');
    }
    let payload: string;
    try {
      payload = JSON.stringify(snapshot);
    } catch (e) {
      throw new Error(`笔记序列化失败：${e}`);
    }
    this.dataPreferences.putSync(SNAPSHOT_KEY, payload);
    const prefsCompat: PreferencesFlushCompat = this.dataPreferences as Object as PreferencesFlushCompat;

    // Prefer sync flush when available to avoid read-after-write races across pages.
    if (typeof prefsCompat.flushSync === 'function') {
      try {
        prefsCompat.flushSync();
        return;
      } catch (e) {
        console.error('flushSync failed:', e);
        throw new Error(`数据持久化失败：${e}`);
      }
    }

    // flush() may be Promise-based or callback-based depending on SDK.
    if (typeof prefsCompat.flush !== 'function') {
      console.warn('flush method not available, data may not be persisted');
      return;
    }

    // Try promise-style (flush(): ThenableVoid)
    try {
      const r = (prefsCompat.flush as () => void | ThenableVoid)();
      if (r && typeof (r as ThenableVoid).then === 'function') {
        await new Promise<void>((resolve, reject) => {
          (r as ThenableVoid).then(() => resolve(), (e: Object) => reject(e));
        });
        return;
      }
    } catch (_) {
      // ignore: might be callback-style
    }

    // callback-style (flush(cb))
    await new Promise<void>((resolve, reject) => {
      try {
        (prefsCompat.flush as Function)((err?: Object) => {
          if (err !== undefined && err !== null) {
            console.error('flush callback error:', err);
            reject(new Error(`数据持久化失败：${err}`));
          } else {
            resolve();
          }
        });
      } catch (e) {
        // If flush doesn't accept callback either, can't await reliably.
        console.error('flush method call failed:', e);
        reject(new Error(`数据持久化失败：${e}`));
      }
    });
  }
}
