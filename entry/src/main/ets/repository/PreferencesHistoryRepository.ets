import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { HistoryRecord } from '../model/HistoryRecord';
import { HistoryRepository } from './HistoryRepository';

const STORE_NAME: string = 'xiaozhou_bookmarks';
const HISTORY_KEY: string = 'history_records';
const MAX_HISTORY_COUNT: number = 300;

export class PreferencesHistoryRepository implements HistoryRepository {
  private readonly context: common.UIAbilityContext;
  private dataPreferences: preferences.Preferences | null = null;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async listRecords(): Promise<HistoryRecord[]> {
    this.ensureStore();
    if (this.dataPreferences === null) {
      return [];
    }
    const raw = this.dataPreferences.getSync(HISTORY_KEY, '') as string;
    if (raw.length === 0) {
      return [];
    }
    try {
      const parsed = JSON.parse(raw) as HistoryRecord[];
      if (!Array.isArray(parsed)) {
        return [];
      }
      return parsed;
    } catch (_) {
      return [];
    }
  }

  async saveRecord(record: HistoryRecord): Promise<void> {
    const current = await this.listRecords();
    const next: HistoryRecord[] = current.filter((item: HistoryRecord) => item.url !== record.url);
    next.unshift({
      id: record.id,
      title: record.title,
      url: record.url,
      visitedAt: record.visitedAt
    });
    if (next.length > MAX_HISTORY_COUNT) {
      next.length = MAX_HISTORY_COUNT;
    }
    this.persist(next);
  }

  async deleteRecord(recordId: string): Promise<void> {
    const current = await this.listRecords();
    const next = current.filter((item: HistoryRecord) => item.id !== recordId);
    this.persist(next);
  }

  async clearAll(): Promise<void> {
    this.persist([]);
  }

  private persist(records: HistoryRecord[]): void {
    this.ensureStore();
    if (this.dataPreferences === null) {
      return;
    }
    this.dataPreferences.putSync(HISTORY_KEY, JSON.stringify(records));
    this.dataPreferences.flush();
  }

  private ensureStore(): void {
    if (this.dataPreferences !== null) {
      return;
    }
    this.dataPreferences = preferences.getPreferencesSync(this.context, { name: STORE_NAME });
  }
}
