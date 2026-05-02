export interface WebDavConfig {
  serverUrl: string;
  username: string;
  password: string;
  remotePath: string;
  noteRemotePath: string;
  syncNotesEnabled: boolean;
  syncImportFullContent: boolean;
  autoSyncOnLaunch: boolean;
  autoSyncOnChange: boolean;
}

export const EMPTY_WEB_DAV_CONFIG: WebDavConfig = {
  serverUrl: 'https://dav.jianguoyun.com/dav/',
  username: '',
  password: '',
  remotePath: '/小舟/书签/bookmarks.json',
  noteRemotePath: '/小舟/笔记',
  syncNotesEnabled: false,
  syncImportFullContent: false,
  autoSyncOnLaunch: false,
  autoSyncOnChange: false
};
