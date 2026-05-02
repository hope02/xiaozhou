import { WebDavConfig } from '../model/WebDavConfig';

export interface WebDavConfigRepository {
  getConfig(): Promise<WebDavConfig>;
  saveConfig(config: WebDavConfig): Promise<void>;
}
