import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DownloadRecord } from '../model/DownloadRecord';
import { DownloadRecordRepository } from './DownloadRecordRepository';

const STORE_NAME: string = 'xiaozhou_downloads';
const DOWNLOADS_KEY: string = 'download_records';

export class PreferencesDownloadRecordRepository implements DownloadRecordRepository {
  private readonly context: common.UIAbilityContext;
  private dataPreferences: preferences.Preferences | null = null;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async listRecords(): Promise<DownloadRecord[]> {
    this.ensureStore();
    if (this.dataPreferences === null) {
      return [];
    }
    const raw = this.dataPreferences.getSync(DOWNLOADS_KEY, '') as string;
    if (raw.length === 0) {
      return [];
    }
    try {
      const parsed = JSON.parse(raw) as DownloadRecord[];
      if (!Array.isArray(parsed)) {
        return [];
      }
      return parsed;
    } catch (_) {
      return [];
    }
  }

  async saveRecord(record: DownloadRecord): Promise<void> {
    const current = await this.listRecords();
    // 更新或添加记录
    const index = current.findIndex(r => r.id === record.id);
    if (index >= 0) {
      current[index] = record;
    } else {
      current.unshift(record);
    }
    this.persist(current);
  }

  async deleteRecord(recordId: string): Promise<void> {
    const current = await this.listRecords();
    const next = current.filter((item: DownloadRecord) => item.id !== recordId);
    this.persist(next);
  }

  async clearAll(): Promise<void> {
    this.persist([]);
  }

  private persist(records: DownloadRecord[]): void {
    this.ensureStore();
    if (this.dataPreferences === null) {
      return;
    }
    this.dataPreferences.putSync(DOWNLOADS_KEY, JSON.stringify(records));
    this.dataPreferences.flush();
  }

  private ensureStore(): void {
    if (this.dataPreferences !== null) {
      return;
    }
    this.dataPreferences = preferences.getPreferencesSync(this.context, { name: STORE_NAME });
  }
}
