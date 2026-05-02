import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { SyncLog } from '../model/SyncLog';
import { SyncLogRepository } from './SyncLogRepository';

const STORE_NAME: string = 'xiaozhou_bookmarks';
const SYNC_LOGS_KEY: string = 'sync_logs';

export class PreferencesSyncLogRepository implements SyncLogRepository {
  private readonly context: common.UIAbilityContext;
  private dataPreferences: preferences.Preferences | null = null;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async listLogs(): Promise<SyncLog[]> {
    this.ensureStore();
    if (this.dataPreferences === null) {
      return [];
    }
    const raw = this.dataPreferences.getSync(SYNC_LOGS_KEY, '') as string;
    if (raw.length === 0) {
      return [];
    }
    try {
      const parsed = JSON.parse(raw) as SyncLog[];
      if (!Array.isArray(parsed)) {
        return [];
      }
      return parsed;
    } catch (_) {
      return [];
    }
  }

  async saveLogs(logs: SyncLog[]): Promise<void> {
    this.ensureStore();
    if (this.dataPreferences === null) {
      return;
    }
    this.dataPreferences.putSync(SYNC_LOGS_KEY, JSON.stringify(logs));
    this.dataPreferences.flush();
  }

  private ensureStore(): void {
    if (this.dataPreferences !== null) {
      return;
    }
    this.dataPreferences = preferences.getPreferencesSync(this.context, { name: STORE_NAME });
  }
}
