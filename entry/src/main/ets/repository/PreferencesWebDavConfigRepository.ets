import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { EMPTY_WEB_DAV_CONFIG, WebDavConfig } from '../model/WebDavConfig';
import { WebDavConfigRepository } from './WebDavConfigRepository';

const STORE_NAME: string = 'xiaozhou_bookmarks';
const WEB_DAV_CONFIG_KEY: string = 'webdav_config';

export class PreferencesWebDavConfigRepository implements WebDavConfigRepository {
  private readonly context: common.UIAbilityContext;
  private dataPreferences: preferences.Preferences | null = null;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async getConfig(): Promise<WebDavConfig> {
    this.ensureStore();
    if (this.dataPreferences === null) {
      return this.defaultConfig();
    }
    const raw = this.dataPreferences.getSync(WEB_DAV_CONFIG_KEY, '') as string;
    if (raw.length === 0) {
      return this.defaultConfig();
    }
    try {
      const parsed = JSON.parse(raw) as WebDavConfig;
      const server = parsed.serverUrl?.trim() ?? '';
      const remote = parsed.remotePath?.trim() ?? '';
      const noteRemote = parsed.noteRemotePath?.trim() ?? '';
      return {
        serverUrl: server.length > 0 ? server : EMPTY_WEB_DAV_CONFIG.serverUrl,
        username: parsed.username ?? '',
        password: parsed.password ?? '',
        remotePath: remote.length > 0 ? remote : EMPTY_WEB_DAV_CONFIG.remotePath,
        noteRemotePath: noteRemote.length > 0 ? noteRemote : EMPTY_WEB_DAV_CONFIG.noteRemotePath,
        syncNotesEnabled: parsed.syncNotesEnabled ?? false,
        syncImportFullContent: parsed.syncImportFullContent ?? false,
        autoSyncOnLaunch: parsed.autoSyncOnLaunch ?? false,
        autoSyncOnChange: parsed.autoSyncOnChange ?? false
      };
    } catch (_) {
      return this.defaultConfig();
    }
  }

  async saveConfig(config: WebDavConfig): Promise<void> {
    this.ensureStore();
    if (this.dataPreferences === null) {
      return;
    }
    this.dataPreferences.putSync(WEB_DAV_CONFIG_KEY, JSON.stringify(config));
    this.dataPreferences.flush();
  }

  private ensureStore(): void {
    if (this.dataPreferences !== null) {
      return;
    }
    this.dataPreferences = preferences.getPreferencesSync(this.context, { name: STORE_NAME });
  }

  private defaultConfig(): WebDavConfig {
    return {
      serverUrl: EMPTY_WEB_DAV_CONFIG.serverUrl,
      username: EMPTY_WEB_DAV_CONFIG.username,
      password: EMPTY_WEB_DAV_CONFIG.password,
      remotePath: EMPTY_WEB_DAV_CONFIG.remotePath,
      noteRemotePath: EMPTY_WEB_DAV_CONFIG.noteRemotePath,
      syncNotesEnabled: EMPTY_WEB_DAV_CONFIG.syncNotesEnabled,
      syncImportFullContent: EMPTY_WEB_DAV_CONFIG.syncImportFullContent,
      autoSyncOnLaunch: EMPTY_WEB_DAV_CONFIG.autoSyncOnLaunch,
      autoSyncOnChange: EMPTY_WEB_DAV_CONFIG.autoSyncOnChange
    };
  }
}
