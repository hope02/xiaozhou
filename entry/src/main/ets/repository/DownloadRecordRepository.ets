import { DownloadRecord } from '../model/DownloadRecord';

export interface DownloadRecordRepository {
  listRecords(): Promise<DownloadRecord[]>;
  saveRecord(record: DownloadRecord): Promise<void>;
  deleteRecord(recordId: string): Promise<void>;
  clearAll(): Promise<void>;
}
