import { Bookmark, BookmarkFolder, BookmarkSnapshot } from '../model/Bookmark';
import { BookmarkRepository } from './BookmarkRepository';

const SCHEMA_VERSION = 1;

export class InMemoryBookmarkRepository implements BookmarkRepository {
  private readonly folders: BookmarkFolder[] = [];
  private readonly bookmarks: Bookmark[] = [];

  async getSnapshot(): Promise<BookmarkSnapshot> {
    return {
      schemaVersion: SCHEMA_VERSION,
      folders: this.folders.slice(),
      bookmarks: this.bookmarks.slice()
    };
  }

  async setSnapshot(snapshot: BookmarkSnapshot): Promise<void> {
    this.folders.length = 0;
    this.bookmarks.length = 0;
    for (const folder of snapshot.folders) {
      this.folders.push({
        id: folder.id,
        name: folder.name,
        updatedAt: folder.updatedAt
      });
    }
    for (const bookmark of snapshot.bookmarks) {
      this.bookmarks.push({
        id: bookmark.id,
        title: bookmark.title,
        url: bookmark.url,
        folderId: bookmark.folderId,
        updatedAt: bookmark.updatedAt,
        deletedFlag: bookmark.deletedFlag
      });
    }
  }

  async listBookmarks(includeDeleted: boolean = false): Promise<Bookmark[]> {
    if (includeDeleted) {
      return this.bookmarks.slice();
    }
    return this.bookmarks.filter((item: Bookmark) => !item.deletedFlag);
  }

  async listFolders(): Promise<BookmarkFolder[]> {
    return this.folders.slice();
  }

  async upsertFolder(folder: BookmarkFolder): Promise<void> {
    const index = this.folders.findIndex((item: BookmarkFolder) => item.id === folder.id);
    if (index < 0) {
      this.folders.push({
        id: folder.id,
        name: folder.name,
        updatedAt: Date.now()
      });
      return;
    }
    this.folders[index].name = folder.name;
    this.folders[index].updatedAt = Date.now();
  }

  async renameFolder(folderId: string, nextName: string): Promise<boolean> {
    const index = this.folders.findIndex((item: BookmarkFolder) => item.id === folderId);
    if (index < 0) {
      return false;
    }
    this.folders[index].name = nextName;
    this.folders[index].updatedAt = Date.now();
    return true;
  }

  async deleteFolder(folderId: string): Promise<boolean> {
    const index = this.folders.findIndex((item: BookmarkFolder) => item.id === folderId);
    if (index < 0) {
      return false;
    }
    this.folders.splice(index, 1);
    for (const bookmark of this.bookmarks) {
      if (bookmark.folderId === folderId) {
        bookmark.folderId = undefined;
        bookmark.updatedAt = Date.now();
      }
    }
    return true;
  }

  async upsertBookmark(bookmark: Bookmark): Promise<void> {
    const index = this.bookmarks.findIndex((item: Bookmark) => item.id === bookmark.id);
    if (index < 0) {
      this.bookmarks.push({
        id: bookmark.id,
        title: bookmark.title,
        url: bookmark.url,
        folderId: bookmark.folderId,
        updatedAt: Date.now(),
        deletedFlag: false
      });
      return;
    }
    const current = this.bookmarks[index];
    current.title = bookmark.title;
    current.url = bookmark.url;
    current.folderId = bookmark.folderId;
    current.deletedFlag = bookmark.deletedFlag;
    current.updatedAt = Date.now();
  }

  async updateBookmarkById(bookmarkId: string, title: string, url: string): Promise<boolean> {
    const index = this.bookmarks.findIndex((item: Bookmark) => item.id === bookmarkId);
    if (index < 0) {
      return false;
    }
    this.bookmarks[index].title = title;
    this.bookmarks[index].url = url;
    this.bookmarks[index].updatedAt = Date.now();
    return true;
  }

  async markBookmarkDeleted(bookmarkId: string): Promise<void> {
    const index = this.bookmarks.findIndex((item: Bookmark) => item.id === bookmarkId);
    if (index < 0) {
      return;
    }
    this.bookmarks[index].deletedFlag = true;
    this.bookmarks[index].updatedAt = Date.now();
  }
}
