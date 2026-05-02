import { Note, NoteFolder, NoteSnapshot, NoteType } from '../model/Note';

export interface NoteRepository {
  getSnapshot(): Promise<NoteSnapshot>;
  setSnapshot(snapshot: NoteSnapshot): Promise<void>;
  listNotes(type?: NoteType, includeDeleted?: boolean): Promise<Note[]>;
  listFolders(): Promise<NoteFolder[]>;
  getNoteById(id: string): Promise<Note | null>;
  upsertNote(note: Note): Promise<void>;
  deleteNote(id: string): Promise<void>;
  hardDeleteNote(id: string): Promise<void>;
  upsertFolder(folder: NoteFolder): Promise<void>;
  deleteFolder(id: string): Promise<void>;
  searchNotes(keyword: string): Promise<Note[]>;
}
