export interface Bookmark {
  id: string;
  title: string;
  url: string;
  favicon?: string;
  folderId?: string;
  updatedAt: number;
  deletedFlag: boolean;
}

export interface BookmarkFolder {
  id: string;
  name: string;
  updatedAt: number;
}

export interface BookmarkSnapshot {
  schemaVersion: number;
  bookmarks: Bookmark[];
  folders: BookmarkFolder[];
}
