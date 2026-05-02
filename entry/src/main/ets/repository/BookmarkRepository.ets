import { Bookmark, BookmarkFolder, BookmarkSnapshot } from '../model/Bookmark';

export interface BookmarkRepository {
  getSnapshot(): Promise<BookmarkSnapshot>;
  setSnapshot(snapshot: BookmarkSnapshot): Promise<void>;
  listBookmarks(includeDeleted?: boolean): Promise<Bookmark[]>;
  listFolders(): Promise<BookmarkFolder[]>;
  upsertFolder(folder: BookmarkFolder): Promise<void>;
  renameFolder(folderId: string, nextName: string): Promise<boolean>;
  deleteFolder(folderId: string): Promise<boolean>;
  upsertBookmark(bookmark: Bookmark): Promise<void>;
  updateBookmarkById(bookmarkId: string, title: string, url: string): Promise<boolean>;
  markBookmarkDeleted(bookmarkId: string): Promise<void>;
}
