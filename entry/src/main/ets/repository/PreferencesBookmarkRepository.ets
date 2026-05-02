import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { Bookmark, BookmarkFolder, BookmarkSnapshot } from '../model/Bookmark';
import { BookmarkRepository } from './BookmarkRepository';

const STORE_NAME: string = 'xiaozhou_bookmarks';
const SNAPSHOT_KEY: string = 'bookmark_snapshot';
const SCHEMA_VERSION: number = 1;

export class PreferencesBookmarkRepository implements BookmarkRepository {
  private readonly context: common.UIAbilityContext;
  private dataPreferences: preferences.Preferences | null = null;
  private readonly fallbackSnapshot: BookmarkSnapshot = {
    schemaVersion: SCHEMA_VERSION,
    bookmarks: [],
    folders: []
  };

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async getSnapshot(): Promise<BookmarkSnapshot> {
    this.ensureStore();
    return this.readSnapshot();
  }

  async setSnapshot(snapshot: BookmarkSnapshot): Promise<void> {
    this.ensureStore();
    this.writeSnapshot(snapshot);
  }

  async listBookmarks(includeDeleted: boolean = false): Promise<Bookmark[]> {
    const snapshot = await this.getSnapshot();
    if (includeDeleted) {
      return snapshot.bookmarks.slice();
    }
    return snapshot.bookmarks.filter((item: Bookmark) => !item.deletedFlag);
  }

  async listFolders(): Promise<BookmarkFolder[]> {
    const snapshot = await this.getSnapshot();
    return snapshot.folders.slice();
  }

  async upsertFolder(folder: BookmarkFolder): Promise<void> {
    this.ensureStore();
    const snapshot = this.readSnapshot();
    const index = snapshot.folders.findIndex((item: BookmarkFolder) => item.id === folder.id);
    if (index < 0) {
      snapshot.folders.push({
        id: folder.id,
        name: folder.name,
        updatedAt: Date.now()
      });
    } else {
      snapshot.folders[index].name = folder.name;
      snapshot.folders[index].updatedAt = Date.now();
    }
    this.writeSnapshot(snapshot);
  }

  async renameFolder(folderId: string, nextName: string): Promise<boolean> {
    this.ensureStore();
    const snapshot = this.readSnapshot();
    const index = snapshot.folders.findIndex((item: BookmarkFolder) => item.id === folderId);
    if (index < 0) {
      return false;
    }
    snapshot.folders[index].name = nextName;
    snapshot.folders[index].updatedAt = Date.now();
    this.writeSnapshot(snapshot);
    return true;
  }

  async deleteFolder(folderId: string): Promise<boolean> {
    this.ensureStore();
    const snapshot = this.readSnapshot();
    const index = snapshot.folders.findIndex((item: BookmarkFolder) => item.id === folderId);
    if (index < 0) {
      return false;
    }
    snapshot.folders.splice(index, 1);
    for (const bookmark of snapshot.bookmarks) {
      if (bookmark.folderId === folderId) {
        bookmark.folderId = undefined;
        bookmark.updatedAt = Date.now();
      }
    }
    this.writeSnapshot(snapshot);
    return true;
  }

  async upsertBookmark(bookmark: Bookmark): Promise<void> {
    this.ensureStore();
    const snapshot = this.readSnapshot();
    const index = snapshot.bookmarks.findIndex((item: Bookmark) => item.id === bookmark.id);
    if (index < 0) {
      snapshot.bookmarks.push({
        id: bookmark.id,
        title: bookmark.title,
        url: bookmark.url,
        favicon: bookmark.favicon,
        folderId: bookmark.folderId,
        updatedAt: Date.now(),
        deletedFlag: false
      });
    } else {
      const current = snapshot.bookmarks[index];
      current.title = bookmark.title;
      current.url = bookmark.url;
      current.favicon = bookmark.favicon;
      current.folderId = bookmark.folderId;
      current.deletedFlag = bookmark.deletedFlag;
      current.updatedAt = Date.now();
    }
    this.writeSnapshot(snapshot);
  }

  async updateBookmarkById(bookmarkId: string, title: string, url: string): Promise<boolean> {
    this.ensureStore();
    const snapshot = this.readSnapshot();
    const index = snapshot.bookmarks.findIndex((item: Bookmark) => item.id === bookmarkId);
    if (index < 0) {
      return false;
    }
    snapshot.bookmarks[index].title = title;
    snapshot.bookmarks[index].url = url;
    snapshot.bookmarks[index].updatedAt = Date.now();
    this.writeSnapshot(snapshot);
    return true;
  }

  async markBookmarkDeleted(bookmarkId: string): Promise<void> {
    this.ensureStore();
    const snapshot = this.readSnapshot();
    const index = snapshot.bookmarks.findIndex((item: Bookmark) => item.id === bookmarkId);
    if (index < 0) {
      return;
    }
    snapshot.bookmarks[index].deletedFlag = true;
    snapshot.bookmarks[index].updatedAt = Date.now();
    this.writeSnapshot(snapshot);
  }

  private ensureStore(): void {
    if (this.dataPreferences !== null) {
      return;
    }
    this.dataPreferences = preferences.getPreferencesSync(this.context, { name: STORE_NAME });
  }

  private readSnapshot(): BookmarkSnapshot {
    if (this.dataPreferences === null) {
      return {
        schemaVersion: SCHEMA_VERSION,
        bookmarks: [],
        folders: []
      };
    }
    const rawValue = this.dataPreferences.getSync(SNAPSHOT_KEY, '') as string;
    if (rawValue.length === 0) {
      return {
        schemaVersion: SCHEMA_VERSION,
        bookmarks: [],
        folders: []
      };
    }

    try {
      const parsed = JSON.parse(rawValue) as BookmarkSnapshot;
      if (!Array.isArray(parsed.bookmarks) || !Array.isArray(parsed.folders)) {
        return this.fallbackSnapshot;
      }
      return {
        schemaVersion: parsed.schemaVersion ?? SCHEMA_VERSION,
        bookmarks: parsed.bookmarks,
        folders: parsed.folders
      };
    } catch (_) {
      return this.fallbackSnapshot;
    }
  }

  private writeSnapshot(snapshot: BookmarkSnapshot): void {
    if (this.dataPreferences === null) {
      return;
    }
    this.dataPreferences.putSync(SNAPSHOT_KEY, JSON.stringify(snapshot));
    this.dataPreferences.flush();
  }
}
