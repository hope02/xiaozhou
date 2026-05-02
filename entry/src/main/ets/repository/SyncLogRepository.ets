import { SyncLog } from '../model/SyncLog';

export interface SyncLogRepository {
  listLogs(): Promise<SyncLog[]>;
  saveLogs(logs: SyncLog[]): Promise<void>;
}
