export type NoteType = 'manual' | 'web_clip' | 'import';

export interface Chapter {
  title: string;
  anchor: string;
  level: number;
}

export interface ImportMeta {
  originalFileName: string;
  fileFormat: 'epub' | 'txt';
  chapterCount: number;
  chapters: Chapter[];
  characterCount: number;
  coverImage?: string;
}

export interface Note {
  id: string;
  type: NoteType;
  title: string;
  content: string;
  contentPlain?: string;
  sourceUrl?: string;
  sourceTitle?: string;
  tags: string[];
  folderId?: string;
  isFavorite: boolean;
  importMeta?: ImportMeta;
  readProgress: number;
  scrollPosition?: string;
  createdAt: number;
  updatedAt: number;
  deletedFlag: boolean;
}

export interface NoteFolder {
  id: string;
  name: string;
  parentId?: string;
  icon?: string;
  color?: string;
  updatedAt: number;
}

export interface NoteSnapshot {
  schemaVersion: number;
  notes: Note[];
  folders: NoteFolder[];
}
