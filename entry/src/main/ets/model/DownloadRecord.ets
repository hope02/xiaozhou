export interface DownloadRecord {
  id: string;
  url: string;
  fileName: string;
  filePath: string;  // 文件保存路径
  totalBytes: number;
  downloadedBytes: number;
  status: 'pending' | 'downloading' | 'completed' | 'failed';
  createdAt: number;
  completedAt?: number;
}
