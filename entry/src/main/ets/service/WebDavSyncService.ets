import { http } from '@kit.NetworkKit';
import { Bookmark, BookmarkFolder, BookmarkSnapshot } from '../model/Bookmark';
import { Note, NoteFolder, NoteSnapshot } from '../model/Note';
import { WebDavConfig } from '../model/WebDavConfig';
import { BookmarkRepository } from '../repository/BookmarkRepository';
import { NoteRepository } from '../repository/NoteRepository';
import { makeBasicAuth } from '../util/Base64Util';

const SCHEMA_VERSION: number = 1;

/** 远端固定布局：书签文件、笔记目录（manifest + 按文件夹层级的 json） */
const REMOTE_BOOKMARK_FILE: string = '/小舟/书签/bookmarks.json';
const REMOTE_NOTE_ROOT: string = '/小舟/笔记';
const REMOTE_NOTE_MANIFEST: string = '/小舟/笔记/manifest.json';

interface WebDavRequestResult {
  code: number;
  body: string;
}

class ExistsCheckResult {
  exists: boolean = false;
  code: number = 0;
}

interface EnsureDirectoryResult {
  success: boolean;
  message: string;
}

interface ErrorLike {
  code?: number | string;
  message?: string;
  name?: string;
  stack?: string;
}

/** 笔记远端索引（用于目录化分文件同步） */
interface NoteManifestEntry {
  id: string;
  updatedAt: number;
  relPath: string;
  deletedFlag: boolean;
}

interface NoteSyncManifest {
  schemaVersion: number;
  folders: NoteFolder[];
  noteIndex: NoteManifestEntry[];
}

export interface SyncExecutionResult {
  message: string;
  success: boolean;
  bookmarkCount: number;
  noteCount: number;
}

export interface ConnectionTestResult {
  success: boolean;
  message: string;
}

export class WebDavSyncService {
  private bookmarkRepository: BookmarkRepository | null = null;
  private noteRepository: NoteRepository | null = null;

  constructor(bookmarkRepository?: BookmarkRepository) {
    if (bookmarkRepository) {
      this.bookmarkRepository = bookmarkRepository;
    }
  }

  setBookmarkRepository(repo: BookmarkRepository): void {
    this.bookmarkRepository = repo;
  }

  setNoteRepository(repo: NoteRepository): void {
    this.noteRepository = repo;
  }

  /**
   * 验证账号密码并确保远端存在 /小舟 目录（不存在则尝试 MKCOL 创建）。
   */
  async testConnection(config: WebDavConfig): Promise<ConnectionTestResult> {
    try {
      const auth = makeBasicAuth(config.username, config.password);
      const serverUrl = config.serverUrl.trim();

      // 参考 OkHttp 实测（native MKCOL）：先用 OPTIONS 探活；鸿蒙 http 无法用字面 MKCOL，仅用 POST+X-HTTP-Method-Override 模拟。
      const davRootUrl = this.resolveRemoteUrl(serverUrl, '/');
      const optProbe = await this.doOptions(davRootUrl, auth);
      if (optProbe.code === 401) {
        return {
          success: false,
          message: '鉴权失败，状态码 401（请核对用户名与「应用密码」，坚果云不支持登录密码）'
        };
      }
      if (optProbe.code === 0) {
        return {
          success: false,
          message: '连接失败：无法连上服务器，请检查网络与 WebDAV 地址（如 https://dav.jianguoyun.com/dav/）'
        };
      }

      let xzEnsure = await this.ensureDirectoryPath(serverUrl, '/小舟', auth);
      if (!xzEnsure.success) {
        const mat = await this.materializeDirectoryDeepByPutMarkers(serverUrl, '/小舟', auth);
        if (!mat) {
          return { success: false, message: xzEnsure.message };
        }
      }

      return {
        success: true,
        message: '连接成功：账号可用，已就绪远端目录 /小舟（书签→/小舟/书签，笔记→/小舟/笔记）'
      };
    } catch (err) {
      const errorMsg = this.errorToMessage(err);
      if (errorMsg.includes('timeout') || errorMsg.includes('Timeout') || errorMsg.includes('timed out')) {
        return { success: false, message: '连接超时，请检查网络与服务器地址' };
      }
      return { success: false, message: `连接异常：${errorMsg}` };
    }
  }

  /** 书签：单文件 `/小舟/书签/bookmarks.json` */
  async sync(config: WebDavConfig): Promise<SyncExecutionResult> {
    if (!this.bookmarkRepository) {
      return { success: false, bookmarkCount: 0, noteCount: 0, message: '本地数据仓库未初始化' };
    }
    const localSnapshot = await this.bookmarkRepository.getSnapshot();
    try {
      const auth = makeBasicAuth(config.username, config.password);
      const serverUrl = config.serverUrl.trim();
      const remotePath = REMOTE_BOOKMARK_FILE;

      const layout = await this.primeWebDavLayout(serverUrl, auth);
      if (!layout.success) {
        return {
          success: false,
          bookmarkCount: this.countActive(localSnapshot),
          noteCount: 0,
          message: `准备远端目录失败：${layout.message}`
        };
      }

      const targetUrl = this.resolveRemoteUrl(serverUrl, remotePath);
      let remoteFetchResult = await this.doGet(targetUrl, auth);
      if (remoteFetchResult.code === 409) {
        await this.materializeDirectoryDeepByPutMarkers(serverUrl, '/小舟/书签', auth);
        remoteFetchResult = await this.doGet(targetUrl, auth);
      }
      if (remoteFetchResult.code === 404) {
        const ensureResult = await this.ensureParentDirsForFile(serverUrl, remotePath, auth);
        if (!ensureResult.success) {
          return {
            success: false,
            bookmarkCount: this.countActive(localSnapshot),
            noteCount: 0,
            message: `${ensureResult.message}。请检查 WebDAV 地址（坚果云常为 …/dav/用户名/）`
          };
        }
        await this.uploadSnapshot(serverUrl, remotePath, auth, localSnapshot);
        const count = this.countActive(localSnapshot);
        return {
          success: true,
          bookmarkCount: count,
          noteCount: 0,
          message: `远端尚无书签文件，已上传 ${count} 条至 ${REMOTE_BOOKMARK_FILE}`
        };
      }
      if (remoteFetchResult.code === 409) {
        const ensureResult = await this.ensureParentDirsForFile(serverUrl, remotePath, auth);
        if (!ensureResult.success) {
          return {
            success: false,
            bookmarkCount: this.countActive(localSnapshot),
            noteCount: 0,
            message: ensureResult.message
          };
        }
        try {
          await this.uploadSnapshot(serverUrl, remotePath, auth, localSnapshot);
          const count = this.countActive(localSnapshot);
          return {
            success: true,
            bookmarkCount: count,
            noteCount: 0,
            message: `路径冲突已处理，已上传本地书签 ${count} 条`
          };
        } catch (_) {
          return {
            success: false,
            bookmarkCount: this.countActive(localSnapshot),
            noteCount: 0,
            message: '书签上传失败（409）。请检查 /小舟/书签 是否为目录占用同名'
          };
        }
      }

      if (remoteFetchResult.code < 200 || remoteFetchResult.code >= 300) {
        return {
          success: false,
          bookmarkCount: this.countActive(localSnapshot),
          noteCount: 0,
          message: `读取远端书签失败，状态码 ${remoteFetchResult.code}`
        };
      }

      const remoteSnapshot = this.parseSnapshot(remoteFetchResult.body);
      const merged = this.mergeSnapshots(localSnapshot, remoteSnapshot);
      await this.bookmarkRepository.setSnapshot(merged);
      await this.uploadSnapshot(serverUrl, remotePath, auth, merged);
      const mergedCount = this.countActive(merged);
      return {
        success: true,
        bookmarkCount: mergedCount,
        noteCount: 0,
        message: `书签同步成功，当前有效 ${mergedCount} 条`
      };
    } catch (err) {
      return {
        success: false,
        bookmarkCount: this.countActive(localSnapshot),
        noteCount: 0,
        message: `请求异常：${this.errorToMessage(err)}`
      };
    }
  }

  /** 笔记：`/小舟/笔记/manifest.json` + `/小舟/笔记/t/.../*.json` 目录结构 */
  async syncNotes(config: WebDavConfig): Promise<SyncExecutionResult> {
    if (!this.noteRepository) {
      return {
        success: false,
        bookmarkCount: 0,
        noteCount: 0,
        message: '本地数据仓库未初始化'
      };
    }

    const localSnapshot = await this.noteRepository.getSnapshot();
    const schemaVersion = localSnapshot.schemaVersion ?? SCHEMA_VERSION;
    try {
      const auth = makeBasicAuth(config.username, config.password);
      const serverUrl = config.serverUrl.trim();

      const layout = await this.primeWebDavLayout(serverUrl, auth);
      if (!layout.success) {
        return {
          success: false,
          bookmarkCount: 0,
          noteCount: this.countActiveNotes(localSnapshot),
          message: `准备远端目录失败：${layout.message}`
        };
      }

      const manifestUrl = this.resolveRemoteUrl(serverUrl, REMOTE_NOTE_MANIFEST);
      let manifestFetch = await this.doGet(manifestUrl, auth);
      if (manifestFetch.code === 409) {
        await this.materializeDirectoryDeepByPutMarkers(serverUrl, '/小舟/笔记', auth);
        manifestFetch = await this.doGet(manifestUrl, auth);
      }
      if (manifestFetch.code === 404 || manifestFetch.code === 409) {
        const ensureRoot = await this.ensureDirectoryPath(serverUrl, REMOTE_NOTE_ROOT, auth);
        if (!ensureRoot.success) {
          return {
            success: false,
            bookmarkCount: 0,
            noteCount: this.countActiveNotes(localSnapshot),
            message: ensureRoot.message
          };
        }
        await this.uploadNotesTree(serverUrl, auth, localSnapshot, config, undefined);
        const count = this.countActiveNotes(localSnapshot);
        return {
          success: true,
          bookmarkCount: 0,
          noteCount: count,
          message: `笔记：远端尚无索引或需初始化，已上传 ${count} 条至 ${REMOTE_NOTE_ROOT}`
        };
      }

      if (manifestFetch.code < 200 || manifestFetch.code >= 300) {
        return {
          success: false,
          bookmarkCount: 0,
          noteCount: this.countActiveNotes(localSnapshot),
          message: `读取笔记索引失败，状态码 ${manifestFetch.code}`
        };
      }

      const remoteManifest = this.parseNoteSyncManifest(manifestFetch.body, schemaVersion);
      const remoteNotes = await this.loadRemoteNotesFromManifest(serverUrl, auth, remoteManifest);
      const remoteSnapshot: NoteSnapshot = {
        schemaVersion: remoteManifest.schemaVersion ?? schemaVersion,
        notes: remoteNotes,
        folders: remoteManifest.folders ?? []
      };
      const merged = this.mergeNoteSnapshots(localSnapshot, remoteSnapshot);
      await this.noteRepository.setSnapshot(merged);
      await this.uploadNotesTree(serverUrl, auth, merged, config, remoteManifest);
      const mergedCount = this.countActiveNotes(merged);
      return {
        success: true,
        bookmarkCount: 0,
        noteCount: mergedCount,
        message: `笔记同步成功，当前有效 ${mergedCount} 条`
      };
    } catch (err) {
      return {
        success: false,
        bookmarkCount: 0,
        noteCount: this.countActiveNotes(localSnapshot),
        message: `同步异常：${this.errorToMessage(err)}`
      };
    }
  }

  async syncAll(config: WebDavConfig): Promise<SyncExecutionResult> {
    const bookmarkResult = await this.sync(config);
    if (!bookmarkResult.success) {
      return bookmarkResult;
    }
    if (config.syncNotesEnabled) {
      const noteResult = await this.syncNotes(config);
      return {
        success: noteResult.success,
        bookmarkCount: bookmarkResult.bookmarkCount,
        noteCount: noteResult.noteCount,
        message: noteResult.success
          ? `书签 ${bookmarkResult.bookmarkCount} 条，笔记 ${noteResult.noteCount} 条`
          : `书签已同步；笔记失败：${noteResult.message}`
      };
    }
    return {
      success: true,
      bookmarkCount: bookmarkResult.bookmarkCount,
      noteCount: 0,
      message: `同步成功，书签有效 ${bookmarkResult.bookmarkCount} 条（笔记同步未开启）`
    };
  }

  private async uploadSnapshot(
    serverUrl: string,
    remotePath: string,
    authHeader: string,
    snapshot: BookmarkSnapshot
  ): Promise<void> {
    const url = this.resolveRemoteUrl(serverUrl, remotePath);
    const body = JSON.stringify(snapshot);

    // 先确保父目录存在
    await this.ensureParentDirsForFile(serverUrl, remotePath, authHeader);

    let putResult = await this.doPut(url, authHeader, body);
    if (putResult.code >= 200 && putResult.code < 300) {
      return;
    }

    // 409 — 路径冲突（被目录/文件占用，或父目录未就绪）
    if (putResult.code === 409) {
      // 确保远端目录链已实体化（部分服务端需要逐级 PUT 占位文件触发创建）
      await this.materializeDirectoryDeepByPutMarkers(serverUrl, '/小舟/书签', authHeader);

      // 尝试删除已有资源（可能是同名目录或残留文件）
      const delCode = (await this.doDelete(url, authHeader)).code;
      if (delCode === 200 || delCode === 204 || delCode === 404) {
        // DELETE 成功或资源不存在 → 重试 PUT
        putResult = await this.doPut(url, authHeader, body);
        if (putResult.code >= 200 && putResult.code < 300) {
          return;
        }
      } else {
        // DELETE 不被服务端支持（如 403/405）→ 直接重试 PUT（部分服务端允许覆盖）
        putResult = await this.doPut(url, authHeader, body);
        if (putResult.code >= 200 && putResult.code < 300) {
          return;
        }
      }
    }

    // 仍失败 → 检查远端路径状态并给出明确指引
    if (putResult.code === 409) {
      const check = await this.remoteResourceExists(serverUrl, remotePath, authHeader);
      if (check.exists) {
        // 远端确实有同名资源阻塞，尝试最后删除一次
        const delCode = (await this.doDelete(url, authHeader)).code;
        if (delCode === 200 || delCode === 204 || delCode === 404) {
          putResult = await this.doPut(url, authHeader, body);
          if (putResult.code >= 200 && putResult.code < 300) {
            return;
          }
        }
        throw new Error(
          `上传失败 409，远端路径被占用：${remotePath}。` +
          `请检查网盘 /小舟/书签/ 下是否有同名文件夹或文件，手动删除后重试`
        );
      }
      throw new Error(
        `上传失败 409，路径冲突（远端 ${remotePath} 不存在但无法创建）。` +
        `请检查 /小舟/书签/ 是否为同名文件而非目录`
      );
    }

    throw new Error(`上传失败 ${putResult.code}`);
  }

  private async loadRemoteNotesFromManifest(
    serverUrl: string,
    authHeader: string,
    manifest: NoteSyncManifest
  ): Promise<Note[]> {
    const result: Note[] = [];
    for (let i = 0; i < manifest.noteIndex.length; i++) {
      const entry = manifest.noteIndex[i];
      const fullPath = `${REMOTE_NOTE_ROOT}/${entry.relPath}`.replace(/\/+/g, '/');
      const url = this.resolveRemoteUrl(serverUrl, fullPath);
      const fetchResult = await this.doGet(url, authHeader);
      if (fetchResult.code >= 200 && fetchResult.code < 300 && fetchResult.body.length > 0) {
        try {
          const n = JSON.parse(fetchResult.body) as Note;
          result.push(n);
        } catch (_) {
          // 跳过损坏条目
        }
      }
    }
    return result;
  }

  private parseNoteSyncManifest(raw: string, schemaVersion: number): NoteSyncManifest {
    if (raw.trim().length === 0) {
      return { schemaVersion: schemaVersion, folders: [], noteIndex: [] };
    }
    try {
      const parsed = JSON.parse(raw) as NoteSyncManifest;
      const folders = Array.isArray(parsed.folders) ? parsed.folders : [];
      const noteIndex = Array.isArray(parsed.noteIndex) ? parsed.noteIndex : [];
      return {
        schemaVersion: parsed.schemaVersion ?? schemaVersion,
        folders: folders,
        noteIndex: noteIndex
      };
    } catch (_) {
      return { schemaVersion: schemaVersion, folders: [], noteIndex: [] };
    }
  }

  private buildFolderMap(folders: NoteFolder[]): Record<string, NoteFolder> {
    const m: Record<string, NoteFolder> = {};
    for (let i = 0; i < folders.length; i++) {
      const f = folders[i];
      m[f.id] = f;
    }
    return m;
  }

  private sanitizePathSegment(id: string): string {
    return id.replace(/\//g, '_');
  }

  private folderChainIds(folderId: string, folderMap: Record<string, NoteFolder>): string[] {
    const chain: string[] = [];
    let cur: string | undefined = folderId;
    let guard = 0;
    while (guard < 100) {
      guard++;
      if (cur === undefined || cur.length === 0) {
        break;
      }
      const idNow: string = cur;
      chain.unshift(idNow);
      const folderEntry: NoteFolder | undefined = folderMap[idNow];
      cur = folderEntry !== undefined ? folderEntry.parentId : undefined;
    }
    return chain;
  }

  private computeNoteRelPath(note: Note, folderMap: Record<string, NoteFolder>): string {
    const nid = this.sanitizePathSegment(note.id);
    if (!note.folderId || note.folderId.length === 0) {
      return `t/_root/${nid}.json`;
    }
    const chain = this.folderChainIds(note.folderId, folderMap);
    const parts: string[] = [];
    for (let i = 0; i < chain.length; i++) {
      parts.push(this.sanitizePathSegment(chain[i]));
    }
    return `t/${parts.join('/')}/${nid}.json`;
  }

  private async uploadNotesTree(
    serverUrl: string,
    authHeader: string,
    merged: NoteSnapshot,
    config: WebDavConfig,
    previousManifest: NoteSyncManifest | undefined
  ): Promise<void> {
    const toSend = this.stripImportContent(merged, config);
    const folderMap = this.buildFolderMap(toSend.folders);

    const oldRelById: Map<string, string> = new Map();
    if (previousManifest !== undefined) {
      for (let i = 0; i < previousManifest.noteIndex.length; i++) {
        const e = previousManifest.noteIndex[i];
        oldRelById.set(e.id, e.relPath);
      }
    }

    const newRelById: Map<string, string> = new Map();
    for (let i = 0; i < toSend.notes.length; i++) {
      const note = toSend.notes[i];
      const rel = this.computeNoteRelPath(note, folderMap);
      newRelById.set(note.id, rel);
      const fullFile = `${REMOTE_NOTE_ROOT}/${rel}`.replace(/\/+/g, '/');
      const ensureResult = await this.ensureParentDirsForFile(serverUrl, fullFile, authHeader);
      if (!ensureResult.success) {
        throw new Error(ensureResult.message);
      }
      const url = this.resolveRemoteUrl(serverUrl, fullFile);
      let putResult = await this.doPut(url, authHeader, JSON.stringify(note));
      if (putResult.code < 200 || putResult.code >= 300) {
        if (putResult.code === 409) {
          await this.doDelete(url, authHeader);
          await this.ensureParentDirsForFile(serverUrl, fullFile, authHeader);
          const parentOnly = fullFile.substring(0, fullFile.lastIndexOf('/'));
          await this.materializeDirectoryDeepByPutMarkers(serverUrl, parentOnly, authHeader);
          putResult = await this.doPut(url, authHeader, JSON.stringify(note));
        }
      }
      if (putResult.code < 200 || putResult.code >= 300) {
        throw new Error(`笔记文件上传失败 ${putResult.code}：${rel}`);
      }
    }

    const oldKeys = Array.from(oldRelById.keys());
    for (let i = 0; i < oldKeys.length; i++) {
      const id = oldKeys[i];
      const oldR = oldRelById.get(id);
      const newR = newRelById.get(id);
      if (oldR !== undefined && newR !== undefined && oldR !== newR) {
        const oldFull = `${REMOTE_NOTE_ROOT}/${oldR}`.replace(/\/+/g, '/');
        await this.tryDelete(this.resolveRemoteUrl(serverUrl, oldFull), authHeader);
      }
    }

    const noteIndex: NoteManifestEntry[] = [];
    for (let i = 0; i < toSend.notes.length; i++) {
      const n = toSend.notes[i];
      const rp = newRelById.get(n.id) ?? this.computeNoteRelPath(n, folderMap);
      const entry: NoteManifestEntry = {
        id: n.id,
        updatedAt: n.updatedAt,
        relPath: rp,
        deletedFlag: n.deletedFlag ?? false
      };
      noteIndex.push(entry);
    }

    const manifest: NoteSyncManifest = {
      schemaVersion: Math.max(SCHEMA_VERSION, merged.schemaVersion),
      folders: toSend.folders.slice(),
      noteIndex: noteIndex
    };
    const manUrl = this.resolveRemoteUrl(serverUrl, REMOTE_NOTE_MANIFEST);
    let manPut = await this.doPut(manUrl, authHeader, JSON.stringify(manifest));
    if (manPut.code < 200 || manPut.code >= 300) {
      if (manPut.code === 409) {
        await this.doDelete(manUrl, authHeader);
        await this.ensureParentDirsForFile(serverUrl, REMOTE_NOTE_MANIFEST, authHeader);
        await this.materializeDirectoryDeepByPutMarkers(serverUrl, REMOTE_NOTE_ROOT, authHeader);
        manPut = await this.doPut(manUrl, authHeader, JSON.stringify(manifest));
      }
    }
    if (manPut.code < 200 || manPut.code >= 300) {
      throw new Error(`manifest 上传失败 ${manPut.code}`);
    }
  }

  private async tryDelete(url: string, authHeader: string): Promise<void> {
    const r = await this.doDelete(url, authHeader);
    if (r.code !== 404 && r.code !== 200 && r.code !== 204 && !(r.code >= 200 && r.code < 300)) {
      // 忽略删除失败（部分服务端不支持 DELETE）
    }
  }

  private async doGet(url: string, authHeader: string): Promise<WebDavRequestResult> {
    const client = http.createHttp();
    try {
      const header: Record<string, string> = {};
      header['Authorization'] = authHeader;
      header['Accept'] = '*/*';
      header['User-Agent'] = 'Mozilla/5.0';
      const requestOptions: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        readTimeout: 20000,
        connectTimeout: 10000
      };
      const response = await client.request(url, requestOptions);
      const resultBody = typeof response.result === 'string' ? response.result : '';
      return { code: response.responseCode, body: resultBody };
    } catch (err) {
      throw new Error(`GET ${url} 失败：${this.errorToMessage(err)}`);
    } finally {
      client.destroy();
    }
  }

  private async doPut(url: string, authHeader: string, body: string): Promise<WebDavRequestResult> {
    const client = http.createHttp();
    try {
      const header: Record<string, string> = {};
      header['Authorization'] = authHeader;
      header['Accept'] = '*/*';
      header['User-Agent'] = 'Mozilla/5.0';
      if (body.length === 0) {
        header['Content-Type'] = 'application/octet-stream';
        header['Content-Length'] = '0';
      } else {
        header['Content-Type'] = 'application/json';
      }
      const requestOptions: http.HttpRequestOptions = {
        method: http.RequestMethod.PUT,
        header: header,
        readTimeout: 30000,
        connectTimeout: 10000,
        extraData: body
      };
      const response = await client.request(url, requestOptions);
      const resultBody = typeof response.result === 'string' ? response.result : '';
      return { code: response.responseCode, body: resultBody };
    } catch (err) {
      throw new Error(`PUT ${url} 失败：${this.errorToMessage(err)}`);
    } finally {
      client.destroy();
    }
  }

  private async doDelete(url: string, authHeader: string): Promise<WebDavRequestResult> {
    const client = http.createHttp();
    try {
      const header: Record<string, string> = {};
      header['Authorization'] = authHeader;
      header['Accept'] = '*/*';
      header['User-Agent'] = 'Mozilla/5.0';
      const requestOptions: http.HttpRequestOptions = {
        method: http.RequestMethod.DELETE,
        header: header,
        readTimeout: 20000,
        connectTimeout: 10000
      };
      const response = await client.request(url, requestOptions);
      const resultBody = typeof response.result === 'string' ? response.result : '';
      return { code: response.responseCode, body: resultBody };
    } catch (_) {
      return { code: 0, body: '' };
    } finally {
      client.destroy();
    }
  }

  /**
   * 与 OkHttp 示例一致：对 WebDAV 根或路径发起 OPTIONS（坚果云可据此判断是否连通）。
   */
  private async doOptions(url: string, authHeader: string): Promise<WebDavRequestResult> {
    const client = http.createHttp();
    try {
      const header: Record<string, string> = {};
      header['Authorization'] = authHeader;
      header['Accept'] = '*/*';
      const requestOptions: http.HttpRequestOptions = {
        method: http.RequestMethod.OPTIONS,
        header: header,
        readTimeout: 15000,
        connectTimeout: 10000
      };
      const response = await client.request(url, requestOptions);
      const resultBody = typeof response.result === 'string' ? response.result : '';
      return { code: response.responseCode, body: resultBody };
    } catch (_) {
      return { code: 0, body: '' };
    } finally {
      client.destroy();
    }
  }

  /** 通用请求方法（HEAD 等标准方法通过此方法发送）。 */
  private async request(
    url: string,
    method: http.RequestMethod,
    authHeader: string,
    body: string
  ): Promise<WebDavRequestResult> {
    if (method === http.RequestMethod.GET) {
      return await this.doGet(url, authHeader);
    }
    if (method === http.RequestMethod.PUT) {
      return await this.doPut(url, authHeader, body);
    }
    const client = http.createHttp();
    try {
      const header: Record<string, string> = {};
      header['Authorization'] = authHeader;
      header['Accept'] = '*/*';
      header['User-Agent'] = 'Mozilla/5.0';
      const requestOptions: http.HttpRequestOptions = {
        method: method,
        header: header,
        readTimeout: 15000,
        connectTimeout: 10000,
        extraData: body
      };
      const response = await client.request(url, requestOptions);
      const resultBody = typeof response.result === 'string' ? response.result : '';
      return { code: response.responseCode, body: resultBody };
    } catch (err) {
      throw new Error(`${method} ${url} 失败：${this.errorToMessage(err)}`);
    } finally {
      client.destroy();
    }
  }

  /**
   * 使用标准 HTTP HEAD 方法检查远端资源是否存在（替代 WebDAV PROPFIND）。
   * 参考 WebdavUploader.java：OkHttp 通过 PROPFIND 检查存在，
   * 鸿蒙 ArkTS 无法发送 PROPFIND，改用 HEAD — 坚果云等标准 WebDAV 服务器均支持 HEAD。
   * 若 HEAD 返回 2xx 或 403/405/301，认定资源存在。
   */
  private async remoteResourceExists(serverUrl: string, remotePath: string, authHeader: string): Promise<ExistsCheckResult> {
    const candidates: string[] = [];
    candidates.push(remotePath);
    if (!remotePath.endsWith('/')) {
      candidates.push(remotePath + '/');
    }
    let lastCode = 0;
    for (let i = 0; i < candidates.length; i++) {
      const url = this.resolveRemoteUrl(serverUrl, candidates[i]);
      try {
        const headResult = await this.request(url, http.RequestMethod.HEAD, authHeader, '');
        lastCode = headResult.code;
        if (headResult.code >= 200 && headResult.code < 300) {
          return { exists: true, code: headResult.code };
        }
        if (headResult.code === 403 || headResult.code === 405 || headResult.code === 301 || headResult.code === 302) {
          return { exists: true, code: headResult.code };
        }
      } catch (_) {
        lastCode = 0;
      }
      try {
        const getResult = await this.doGet(url, authHeader);
        lastCode = getResult.code;
        if (getResult.code >= 200 && getResult.code < 300) {
          return { exists: true, code: getResult.code };
        }
        if (getResult.code === 403 || getResult.code === 405 || getResult.code === 301 || getResult.code === 302) {
          return { exists: true, code: getResult.code };
        }
      } catch (_) {
        lastCode = 0;
      }
    }
    return { exists: false, code: lastCode };
  }

  /** 在目录下写入占位文件，坚果云等会在 PUT 文件时逐级创建父目录（替代 MKCOL）。 */
  private async putDirectoryMarker(serverUrl: string, dirAbsolutePath: string, authHeader: string): Promise<WebDavRequestResult> {
    const trimmed = dirAbsolutePath.endsWith('/') ? dirAbsolutePath.slice(0, -1) : dirAbsolutePath;
    const markerPath = `${trimmed}/.xiaozhou_keep`;
    const url = this.resolveRemoteUrl(serverUrl, markerPath);
    return await this.doPut(url, authHeader, ' ');
  }

  /** 从浅到深依次 PUT `.xiaozhou_keep`，用于整条路径不存在时的目录链创建 */
  private async materializeDirectoryDeepByPutMarkers(
    serverUrl: string,
    absoluteDirPath: string,
    authHeader: string
  ): Promise<boolean> {
    const trimmed = absoluteDirPath.endsWith('/') ? absoluteDirPath.slice(0, -1) : absoluteDirPath;
    const segments = trimmed.split('/').filter((p: string) => p.length > 0);
    let current = '';
    for (let i = 0; i < segments.length; i++) {
      current += `/${segments[i]}`;
      const res = await this.putDirectoryMarker(serverUrl, current, authHeader);
      if (res.code >= 200 && res.code < 300 || res.code === 409) {
        continue;
      }
      if (res.code === 401 || res.code === 403) {
        return false;
      }
    }
    return true;
  }

  /** 同步前确保标准目录存在（仅用 PUT 占位文件，无需 MKCOL）。 */
  private async primeWebDavLayout(serverUrl: string, authHeader: string): Promise<EnsureDirectoryResult> {
    const m1 = await this.materializeDirectoryDeepByPutMarkers(serverUrl, '/小舟/书签', authHeader);
    const m2 = await this.materializeDirectoryDeepByPutMarkers(serverUrl, '/小舟/笔记', authHeader);
    if (m1 && m2) {
      return { success: true, message: '布局就绪' };
    }
    return { success: false, message: '无法创建远端目录结构，请检查权限' };
  }

  /**
   * 创建完整目录链，例如 `/小舟/笔记/t/a`。
   * 参考 WebdavUploader.java：坚果云等服务器在 PUT 文件时自动创建父目录。
   * 因此无需 MKCOL 命令，直接通过 PUT 占位文件驱动目录创建。
   */
  private async ensureDirectoryPath(serverUrl: string, absoluteDirPath: string, authHeader: string): Promise<EnsureDirectoryResult> {
    const trimmed = absoluteDirPath.endsWith('/') ? absoluteDirPath.slice(0, -1) : absoluteDirPath;
    if (!trimmed.startsWith('/') || trimmed.length < 2) {
      return { success: true, message: '跳过' };
    }
    const segments = trimmed.split('/').filter((part: string) => part.length > 0);
    if (segments.length === 0) {
      return { success: true, message: '远端目录检查通过' };
    }

    const firstSegmentPath = `/${segments[0]}`;
    const jianguoyunBaseHint = (): string => {
      const s = (serverUrl ?? '').trim();
      if (s.includes('dav.jianguoyun.com') && (s.endsWith('/dav') || s.endsWith('/dav/'))) {
        return '（提示：坚果云通常需将服务器地址设为 https://dav.jianguoyun.com/dav/你的用户名/ ）';
      }
      return '';
    };

    let current = '';
    for (let si = 0; si < segments.length; si++) {
      current += `/${segments[si]}`;

      // 先检查目录是否已存在（HEAD/GET，无需 PROPFIND）
      const check = await this.remoteResourceExists(serverUrl, current, authHeader);
      if (check.exists) {
        continue;
      }

      // 不存在则 PUT 占位文件通知服务器创建目录
      const markPut = await this.putDirectoryMarker(serverUrl, current, authHeader);
      if (markPut.code >= 200 && markPut.code < 300) {
        continue;
      }

      if (markPut.code === 401 || markPut.code === 403) {
        return {
          success: false,
          message: `鉴权失败（${markPut.code}），无法在远端创建 ${current}（请核对应用密码与服务器地址是否含用户名路径）`
        };
      }
      if (markPut.code === 409) {
        // 409 通常表示资源冲突，但有时服务器会先创建目录再返回 409
        continue;
      }

      return {
        success: false,
        message: `自动创建目录失败：${current}。请在网盘中手动创建后重试${current === firstSegmentPath ? jianguoyunBaseHint() : ''}`
      };
    }

    return { success: true, message: '远端目录准备完成' };
  }

  /** 确保远端文件路径的父目录均已创建 */
  private async ensureParentDirsForFile(serverUrl: string, remoteFilePath: string, authHeader: string): Promise<EnsureDirectoryResult> {
    const normalized = remoteFilePath.startsWith('/') ? remoteFilePath : `/${remoteFilePath}`;
    const lastSlash = normalized.lastIndexOf('/');
    if (lastSlash <= 0) {
      return { success: true, message: 'ok' };
    }
    const parentDir = normalized.substring(0, lastSlash);
    if (parentDir.length === 0) {
      return { success: true, message: 'ok' };
    }
    return await this.ensureDirectoryPath(serverUrl, parentDir, authHeader);
  }

  private parseSnapshot(raw: string): BookmarkSnapshot {
    if (raw.trim().length === 0) {
      return this.emptySnapshot();
    }
    try {
      const parsed = JSON.parse(raw) as BookmarkSnapshot;
      if (!Array.isArray(parsed.bookmarks) || !Array.isArray(parsed.folders)) {
        return this.emptySnapshot();
      }
      return {
        schemaVersion: parsed.schemaVersion ?? SCHEMA_VERSION,
        bookmarks: parsed.bookmarks,
        folders: parsed.folders
      };
    } catch (_) {
      return this.emptySnapshot();
    }
  }

  private mergeSnapshots(local: BookmarkSnapshot, remote: BookmarkSnapshot): BookmarkSnapshot {
    const mergedBookmarks = this.mergeBookmarks(local.bookmarks, remote.bookmarks);
    const mergedFolders = this.mergeFolders(local.folders, remote.folders);
    return {
      schemaVersion: SCHEMA_VERSION,
      bookmarks: mergedBookmarks,
      folders: mergedFolders
    };
  }

  private mergeBookmarks(local: Bookmark[], remote: Bookmark[]): Bookmark[] {
    const result: Bookmark[] = [];
    const indexMap: Record<string, number> = {};
    for (const item of local) {
      const copied: Bookmark = {
        id: item.id,
        title: item.title,
        url: item.url,
        folderId: item.folderId,
        updatedAt: item.updatedAt,
        deletedFlag: item.deletedFlag
      };
      indexMap[copied.id] = result.length;
      result.push(copied);
    }
    for (const item of remote) {
      const existingIndex = indexMap[item.id];
      if (existingIndex === undefined) {
        result.push({
          id: item.id,
          title: item.title,
          url: item.url,
          folderId: item.folderId,
          updatedAt: item.updatedAt,
          deletedFlag: item.deletedFlag
        });
        indexMap[item.id] = result.length - 1;
        continue;
      }
      if (item.updatedAt > result[existingIndex].updatedAt) {
        result[existingIndex] = {
          id: item.id,
          title: item.title,
          url: item.url,
          folderId: item.folderId,
          updatedAt: item.updatedAt,
          deletedFlag: item.deletedFlag
        };
      }
    }
    return result;
  }

  private mergeFolders(local: BookmarkFolder[], remote: BookmarkFolder[]): BookmarkFolder[] {
    const result: BookmarkFolder[] = [];
    const indexMap: Record<string, number> = {};
    for (const item of local) {
      result.push({
        id: item.id,
        name: item.name,
        updatedAt: item.updatedAt
      });
      indexMap[item.id] = result.length - 1;
    }
    for (const item of remote) {
      const existingIndex = indexMap[item.id];
      if (existingIndex === undefined) {
        result.push({
          id: item.id,
          name: item.name,
          updatedAt: item.updatedAt
        });
        indexMap[item.id] = result.length - 1;
        continue;
      }
      if (item.updatedAt > result[existingIndex].updatedAt) {
        result[existingIndex] = {
          id: item.id,
          name: item.name,
          updatedAt: item.updatedAt
        };
      }
    }
    return result;
  }

  private resolveRemoteUrl(serverUrl: string, remotePath: string): string {
    const server = serverUrl.endsWith('/') ? serverUrl.slice(0, -1) : serverUrl;
    const path = remotePath.startsWith('/') ? remotePath : `/${remotePath}`;
    const encodedPath = path
      .split('/')
      .map((seg: string) => (seg.length === 0 ? '' : encodeURIComponent(seg)))
      .join('/');
    return `${server}${encodedPath}`;
  }

  private emptySnapshot(): BookmarkSnapshot {
    return {
      schemaVersion: SCHEMA_VERSION,
      bookmarks: [],
      folders: []
    };
  }

  private countActive(snapshot: BookmarkSnapshot): number {
    return snapshot.bookmarks.filter((item: Bookmark) => !item.deletedFlag).length;
  }

  private mergeNoteSnapshots(local: NoteSnapshot, remote: NoteSnapshot): NoteSnapshot {
    return {
      schemaVersion: Math.max(local.schemaVersion, remote.schemaVersion),
      notes: this.mergeNotes(local.notes, remote.notes),
      folders: this.mergeNoteFolders(local.folders, remote.folders)
    };
  }

  private mergeNotes(local: Note[], remote: Note[]): Note[] {
    const result: Note[] = [];
    const indexMap: Record<string, number> = {};
    for (const item of local) {
      result.push(this.copyNote(item));
      indexMap[item.id] = result.length - 1;
    }
    for (const item of remote) {
      const existingIndex = indexMap[item.id];
      if (existingIndex === undefined) {
        result.push(this.copyNote(item));
        indexMap[item.id] = result.length - 1;
        continue;
      }
      const existing = result[existingIndex];
      const remoteHasContent = item.content && item.content.length > 100;
      const localHasContent = existing.content && existing.content.length > 100;
      if (!remoteHasContent && localHasContent) {
        continue;
      }
      if (remoteHasContent && !localHasContent) {
        result[existingIndex] = this.copyNote(item);
        continue;
      }
      if (item.updatedAt > existing.updatedAt) {
        result[existingIndex] = this.copyNote(item);
      }
    }
    return result;
  }

  private mergeNoteFolders(local: NoteFolder[], remote: NoteFolder[]): NoteFolder[] {
    const result: NoteFolder[] = [];
    const indexMap: Record<string, number> = {};
    for (const item of local) {
      const copy: NoteFolder = this.copyFolder(item);
      result.push(copy);
      indexMap[item.id] = result.length - 1;
    }
    for (const item of remote) {
      const existingIndex = indexMap[item.id];
      if (existingIndex === undefined) {
        const copy: NoteFolder = this.copyFolder(item);
        result.push(copy);
        indexMap[item.id] = result.length - 1;
        continue;
      }
      if (item.updatedAt > result[existingIndex].updatedAt) {
        result[existingIndex] = this.copyFolder(item);
      }
    }
    return result;
  }

  private copyFolder(f: NoteFolder): NoteFolder {
    return {
      id: f.id,
      name: f.name,
      parentId: f.parentId,
      icon: f.icon,
      color: f.color,
      updatedAt: f.updatedAt
    };
  }

  private copyNote(n: Note): Note {
    return {
      id: n.id,
      type: n.type,
      title: n.title,
      content: n.content,
      contentPlain: n.contentPlain,
      sourceUrl: n.sourceUrl,
      sourceTitle: n.sourceTitle,
      tags: n.tags ? n.tags.slice() : [],
      folderId: n.folderId,
      isFavorite: n.isFavorite ?? false,
      importMeta: n.importMeta,
      readProgress: n.readProgress ?? 0,
      scrollPosition: n.scrollPosition,
      createdAt: n.createdAt,
      updatedAt: n.updatedAt,
      deletedFlag: n.deletedFlag ?? false
    };
  }

  private countActiveNotes(snapshot: NoteSnapshot): number {
    return snapshot.notes.filter((item: Note) => !item.deletedFlag).length;
  }

  private stripImportContent(snapshot: NoteSnapshot, config: WebDavConfig): NoteSnapshot {
    if (config.syncImportFullContent) {
      return snapshot;
    }
    const stripped = snapshot.notes.map((n: Note) => {
      if (n.type === 'import' && n.content && n.content.length > 1024) {
        const copy: Note = this.copyNote(n);
        copy.content = '[content stripped for sync]';
        copy.contentPlain = n.contentPlain ? n.contentPlain.substring(0, 100) : undefined;
        return copy;
      }
      return n;
    });
    return {
      schemaVersion: snapshot.schemaVersion,
      notes: stripped,
      folders: snapshot.folders.slice()
    };
  }

  private errorToMessage(err: Object): string {
    const e = err as ErrorLike;
    const hasCode = e.code !== undefined;
    const hasMessage = e.message !== undefined && e.message.length > 0;
    const hasName = e.name !== undefined && e.name.length > 0;
    let text = '';
    if (hasCode) {
      text += `code=${e.code}; `;
    }
    if (hasName) {
      text += `name=${e.name}; `;
    }
    if (hasMessage) {
      text += `message=${e.message}; `;
    }
    if (e.stack !== undefined && e.stack.length > 0) {
      text += `stack=${e.stack}; `;
    }
    const trimmed = text.trim();
    if (trimmed.length > 0) {
      return trimmed;
    }
    const asString = `${err}`;
    if (asString.length > 0 && asString !== '[object Object]') {
      return asString;
    }
    const asJson = JSON.stringify(err);
    if (asJson.length > 0 && asJson !== '{}') {
      return asJson;
    }
    if (hasName && !hasCode && !hasMessage) {
      return 'name=Error; 可能原因：HTTPS 证书、域名解析、网络不可达或服务拒绝连接';
    }
    return '未知错误（异常对象无可读字段）';
  }
}
