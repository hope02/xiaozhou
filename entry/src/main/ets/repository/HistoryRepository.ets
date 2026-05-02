import { HistoryRecord } from '../model/HistoryRecord';

export interface HistoryRepository {
  listRecords(): Promise<HistoryRecord[]>;
  saveRecord(record: HistoryRecord): Promise<void>;
  deleteRecord(recordId: string): Promise<void>;
  clearAll(): Promise<void>;
}
