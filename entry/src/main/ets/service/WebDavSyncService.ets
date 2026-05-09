import { http } from '@kit.NetworkKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { Bookmark, BookmarkFolder, BookmarkSnapshot } from '../model/Bookmark';
import { WebDavConfig } from '../model/WebDavConfig';
import { BookmarkRepository } from '../repository/BookmarkRepository';
import { NoteRepository } from '../repository/NoteRepository';
import { Note, NoteFolder, NoteSnapshot } from '../model/Note';
import { makeBasicAuth } from '../util/Base64Util';

// ─────────────────────────────────────────────────────────────────────────────
// 设计说明
//
// 坚果云 WebDAV 行为：
//   1. PUT **不会**自动创建父目录，父目录不存在时 PUT 返回 409 Conflict
//   2. MKCOL 是创建目录的标准 WebDAV 方法，必须逐级创建
//   3. MKCOL 对已存在目录：坚果云严格返回 409（部分服务器返回 405）
//
// HarmonyOS HTTP 限制：
//   @kit.NetworkKit 的 http.RequestMethod 枚举仅含 8 种标准方法，不含 MKCOL。
//   用 'MKCOL' as http.RequestMethod 强转可能不被底层接受。
//
// 解决方案：
//   使用 @kit.RemoteCommunicationKit (rcp) 发送 MKCOL 请求。
//   rcp 的 HttpMethod 类型 = 标准 7 种 | (string & NonNullable<unknown>)，
//   编译期支持任意字符串（如 'MKCOL'），运行时正确发出请求。
//
// 本服务对所有 MKCOL 请求统一走 rcp，其他请求 (GET/PUT/OPTIONS) 走 @kit.NetworkKit。
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Public result types
// ─────────────────────────────────────────────────────────────────────────────

export interface ConnectionTestResult {
  success: boolean;
  message: string;
}

export interface SyncExecutionResult {
  success: boolean;
  message: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────────────────

interface HttpExecResult {
  code: number;
  body: string;
}

/** 拼接 DAV URL，对路径分段做 encodeURIComponent */
function joinDavUrl(serverUrl: string, remotePath: string): string {
  let base = serverUrl.trim();
  if (!base.endsWith('/')) {
    base += '/';
  }
  const trimmed = remotePath.trim();
  const withoutLeading = trimmed.startsWith('/') ? trimmed.substring(1) : trimmed;
  const segments = withoutLeading.split('/').filter((s: string) => s.length > 0);
  const encoded = segments.map((s: string) => encodeURIComponent(s)).join('/');
  return base + encoded;
}

/** 规范化服务器根 URL */
function normalizeDavRoot(serverUrl: string): string {
  let base = serverUrl.trim();
  if (!base.endsWith('/')) {
    base += '/';
  }
  return base;
}

/** OPTIONS/GET 根路径可接受的状态码 */
function isDavRootReachable(code: number): boolean {
  return code === 200 || code === 204 || code === 207 || code === 404;
}

/**
 * 列出远程文件路径的所有父级目录，从浅到深。
 * 例如 /小舟/笔记/2024 -> ['/小舟', '/小舟/笔记']
 */
function listParentFolderPaths(remoteFilePath: string): string[] {
  const trimmed = remoteFilePath.trim();
  const base = trimmed.startsWith('/') ? trimmed.substring(1) : trimmed;
  const segments = base.split('/').filter((s: string) => s.length > 0);
  if (segments.length <= 1) {
    return [];
  }
  const parents: string[] = [];
  for (let i = 0; i < segments.length - 1; i++) {
    const slice = segments.slice(0, i + 1);
    parents.push(`/${slice.join('/')}`);
  }
  return parents;
}

/**
 * 列出一个目录路径本身及其所有父级（从浅到深）。
 * 用于确保笔记目录自身也被 MKCOL 创建。
 * 例如 /小舟/笔记 -> ['/小舟', '/小舟/笔记']
 */
function listDirAndParentPaths(remoteDirPath: string): string[] {
  const trimmed = remoteDirPath.trim();
  const base = trimmed.startsWith('/') ? trimmed.substring(1) : trimmed;
  const segments = base.split('/').filter((s: string) => s.length > 0);
  if (segments.length === 0) {
    return [];
  }
  const paths: string[] = [];
  for (let i = 0; i < segments.length; i++) {
    const slice = segments.slice(0, i + 1);
    paths.push(`/${slice.join('/')}`);
  }
  return paths;
}

/**
 * MKCOL 成功/已存在的状态码。
 * - 201: 创建成功
 * - 200/204: 部分服务器返回
 * - 301/302: 重定向（坚果云偶发）—— 目录通常已存在，按成功处理
 * - 405: Method Not Allowed —— 目录已存在（多数 WebDAV 服务器行为）
 * - 409: 坚果云对已存在目录也返回 409，按已存在处理
 */
function isMkcolSuccess(code: number): boolean {
  return code === 201 || code === 200 || code === 204
    || code === 301 || code === 302
    || code === 405 || code === 409;
}

/**
 * 判断 GET 文件时返回的状态码是否意味着"文件不存在"。
 * - 404: 标准不存在
 * - 409: 坚果云在父目录不存在时对 GET 也会返回 409
 */
function isFileNotFound(code: number): boolean {
  return code === 404 || code === 409;
}

/** 将异常对象转为可读字符串 */
function exceptionToDetail(err: Object): string {
  try {
    const json = JSON.stringify(err);
    if (json.length > 2 && json !== '{}') {
      return json.length > 300 ? `${json.substring(0, 300)}…` : json;
    }
  } catch (_) {
  }
  const fallback = `${err}`;
  if (fallback.length > 0 && fallback !== '[object Object]' && fallback !== 'undefined') {
    return fallback.length > 300 ? `${fallback.substring(0, 300)}…` : fallback;
  }
  return '网络或 TLS 异常（无详细信息）';
}

/** 将响应体统一为可读字符串 */
function normalizeResponseBody(result: Object | string | undefined | null): string {
  if (result === undefined || result === null) {
    return '';
  }
  if (typeof result === 'string') {
    return result;
  }
  try {
    const j = JSON.stringify(result);
    return j.length > 500 ? `${j.substring(0, 500)}…` : j;
  } catch (_) {
    return '(无法解析的响应体)';
  }
}

function mergeBookmarkSnapshots(local: BookmarkSnapshot, remote: BookmarkSnapshot): BookmarkSnapshot {
  const schemaVersion = Math.max(local.schemaVersion, remote.schemaVersion);
  const folderMap: Map<string, BookmarkFolder> = new Map();
  for (let i = 0; i < remote.folders.length; i++) {
    folderMap.set(remote.folders[i].id, remote.folders[i]);
  }
  for (let i = 0; i < local.folders.length; i++) {
    const f = local.folders[i];
    const prev = folderMap.get(f.id);
    if (prev === undefined || f.updatedAt > prev.updatedAt) {
      folderMap.set(f.id, f);
    }
  }
  const mergedFolders: BookmarkFolder[] = [];
  folderMap.forEach((v: BookmarkFolder) => {
    mergedFolders.push(v);
  });

  const bookmarkMap: Map<string, Bookmark> = new Map();
  for (let i = 0; i < remote.bookmarks.length; i++) {
    bookmarkMap.set(remote.bookmarks[i].id, remote.bookmarks[i]);
  }
  for (let i = 0; i < local.bookmarks.length; i++) {
    const b = local.bookmarks[i];
    const prev = bookmarkMap.get(b.id);
    if (prev === undefined || b.updatedAt > prev.updatedAt) {
      bookmarkMap.set(b.id, b);
    }
  }
  const mergedBookmarks: Bookmark[] = [];
  bookmarkMap.forEach((v: Bookmark) => {
    mergedBookmarks.push(v);
  });
  return { schemaVersion, folders: mergedFolders, bookmarks: mergedBookmarks };
}

function mergeNoteSnapshots(local: NoteSnapshot, remote: NoteSnapshot): NoteSnapshot {
  const schemaVersion = Math.max(local.schemaVersion, remote.schemaVersion);

  const folderMap: Map<string, NoteFolder> = new Map();
  for (const f of remote.folders) {
    folderMap.set(f.id, f);
  }
  for (const f of local.folders) {
    const prev = folderMap.get(f.id);
    if (prev === undefined || f.updatedAt > prev.updatedAt) {
      folderMap.set(f.id, f);
    }
  }
  const mergedFolders: NoteFolder[] = [];
  folderMap.forEach((v: NoteFolder) => mergedFolders.push(v));

  const noteMap: Map<string, Note> = new Map();
  for (const n of remote.notes) {
    noteMap.set(n.id, n);
  }
  for (const n of local.notes) {
    const prev = noteMap.get(n.id);
    if (prev === undefined || n.updatedAt > prev.updatedAt) {
      noteMap.set(n.id, n);
    }
  }
  const mergedNotes: Note[] = [];
  noteMap.forEach((v: Note) => mergedNotes.push(v));

  return { schemaVersion, notes: mergedNotes, folders: mergedFolders };
}

// ─────────────────────────────────────────────────────────────────────────────
// Main service
// ─────────────────────────────────────────────────────────────────────────────

export class WebDavSyncService {
  private readonly bookmarkRepository: BookmarkRepository;
  private noteRepository: NoteRepository | null = null;

  constructor(bookmarkRepository: BookmarkRepository) {
    this.bookmarkRepository = bookmarkRepository;
  }

  setNoteRepository(repo: NoteRepository): void {
    this.noteRepository = repo;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // testConnection
  // ───────────────────────────────────────────────────────────────────────────

  async testConnection(config: WebDavConfig): Promise<ConnectionTestResult> {
    // 1. 探测根路径可达性
    const rootUrl = normalizeDavRoot(config.serverUrl);
    let rootProbe = await this.execHttp(config, http.RequestMethod.OPTIONS, rootUrl, undefined);
    if (rootProbe.code === -1) {
      return { success: false, message: `连接失败：${rootProbe.body}` };
    }
    if (!isDavRootReachable(rootProbe.code)) {
      rootProbe = await this.execHttp(config, http.RequestMethod.GET, rootUrl, undefined);
    }
    if (rootProbe.code === -1) {
      return { success: false, message: `连接失败：${rootProbe.body}` };
    }
    if (rootProbe.code === 401) {
      return {
        success: false,
        message: '认证失败（401）。若使用坚果云，请在「账户信息 → 安全选项」生成「第三方应用密码」，勿使用网页登录密码'
      };
    }
    if (rootProbe.code === 403) {
      return { success: false, message: '没有权限访问 WebDAV（403）' };
    }
    if (!isDavRootReachable(rootProbe.code)) {
      return {
        success: false,
        message: `WebDAV 根路径响应 HTTP ${rootProbe.code}（请确认地址以 /dav/ 结尾）`
      };
    }

    // 2. 尝试预建书签父目录（软失败，不阻断）
    const mkdirWarn = await this.ensureParentDirsSoft(config, config.remotePath);

    // 3. 探测书签文件
    const fileUrl = joinDavUrl(config.serverUrl, config.remotePath);
    const fileProbe = await this.execHttp(config, http.RequestMethod.GET, fileUrl, undefined);
    if (fileProbe.code === -1) {
      return {
        success: false,
        message: `服务器与账号可用，但检测书签路径失败：${fileProbe.body}`
      };
    }
    if (fileProbe.code === 200 || fileProbe.code === 207) {
      const warn = mkdirWarn ? `（目录提示：${mkdirWarn}）` : '';
      return { success: true, message: `连接成功，远程书签文件可读${warn}` };
    }
    // 404 或 409 都表示文件不存在（409 可能是父目录尚未创建）
    if (isFileNotFound(fileProbe.code)) {
      return {
        success: true,
        message: '连接成功，远程书签文件尚不存在（首次同步将自动创建目录和文件）'
      };
    }
    if (fileProbe.code === 401) {
      return { success: false, message: '认证失败（401），请检查用户名与应用专用密码' };
    }
    if (fileProbe.code === 403) {
      return { success: false, message: '没有权限访问该书签路径（403）' };
    }
    return {
      success: false,
      message: `书签路径检测失败（HTTP ${fileProbe.code}），根路径已连通`
    };
  }

  // ───────────────────────────────────────────────────────────────────────────
  // syncAll
  // ───────────────────────────────────────────────────────────────────────────

  async syncAll(config: WebDavConfig): Promise<SyncExecutionResult> {
    // ── 书签同步 ──────────────────────────────────────────────────────────────
    const bookmarkResult = await this.syncBookmarks(config);
    if (!bookmarkResult.success) {
      return bookmarkResult;
    }

    // ── 笔记同步（可选，若 noteRepository 未设置则跳过）────────────────────────
    if (config.syncNotesEnabled && this.noteRepository !== null) {
      const noteResult = await this.syncNotes(config);
      if (!noteResult.success) {
        // 笔记失败不阻断，返回带警告的成功
        return {
          success: true,
          message: `书签已同步；笔记同步失败：${noteResult.message}`
        };
      }
      return { success: true, message: '书签与笔记均已与云端同步' };
    }

    return bookmarkResult;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // syncBookmarks (内部)
  // ───────────────────────────────────────────────────────────────────────────

  private async syncBookmarks(config: WebDavConfig): Promise<SyncExecutionResult> {
    const bookmarkUrl = joinDavUrl(config.serverUrl, config.remotePath);
    const localBookmarks = await this.bookmarkRepository.getSnapshot();

    // 1. 确保父目录存在（软失败：MKCOL 失败不阻断，后面 PUT 失败再处理）
    await this.ensureParentDirsSoft(config, config.remotePath);

    // 2. 拉取远程书签
    const remoteFetch = await this.execHttp(config, http.RequestMethod.GET, bookmarkUrl, undefined);
    let mergedBookmarks: BookmarkSnapshot = localBookmarks;

    if (remoteFetch.code === 200 || remoteFetch.code === 207) {
      const parsed = this.parseBookmarkSnapshot(remoteFetch.body);
      if (parsed === null) {
        return { success: false, message: '远程书签文件格式无效，已中止同步以免覆盖数据' };
      }
      mergedBookmarks = mergeBookmarkSnapshots(localBookmarks, parsed);
    } else if (isFileNotFound(remoteFetch.code)) {
      // 404 或 409：文件/目录不存在，以本地数据为准
      mergedBookmarks = localBookmarks;
    } else if (remoteFetch.code === 401 || remoteFetch.code === 403) {
      return {
        success: false,
        message: `拉取远程书签失败（HTTP ${remoteFetch.code}），请检查账号或路径权限`
      };
    } else if (remoteFetch.code !== -1) {
      return { success: false, message: `拉取远程书签失败（HTTP ${remoteFetch.code}）` };
    } else {
      return { success: false, message: `拉取远程书签失败：${remoteFetch.body}` };
    }

    // 3. 本地写入合并结果
    await this.bookmarkRepository.setSnapshot(mergedBookmarks);
    const bookmarkBody = JSON.stringify(mergedBookmarks);

    // 4. 上传合并结果
    let putResult = await this.execHttp(config, http.RequestMethod.PUT, bookmarkUrl, bookmarkBody);
    // 若 PUT 返回 409（父目录不存在），强制 MKCOL 建目录后重试
    if (putResult.code === 409) {
      const mkdirError = await this.ensureParentDirsHard(config, config.remotePath);
      if (mkdirError !== null) {
        return {
          success: false,
          message: `上传书签失败：${mkdirError}。请手动在云盘建立「小舟」文件夹后重试`
        };
      }
      putResult = await this.execHttp(config, http.RequestMethod.PUT, bookmarkUrl, bookmarkBody);
    }
    if (putResult.code !== 200 && putResult.code !== 201 && putResult.code !== 204) {
      return {
        success: false,
        message: `上传书签失败（HTTP ${putResult.code}），本地已合并但未写入云端`
      };
    }

    return { success: true, message: '书签已与云端合并并完成上传' };
  }

  // ───────────────────────────────────────────────────────────────────────────
  // syncNotes (内部)
  // ───────────────────────────────────────────────────────────────────────────

  private async syncNotes(config: WebDavConfig): Promise<SyncExecutionResult> {
    if (this.noteRepository === null) {
      return { success: false, message: '笔记仓库未初始化' };
    }

    // 笔记以单一 JSON 快照形式存储：noteRemotePath/notes.json
    const noteDir = config.noteRemotePath.trim().length > 0 ? config.noteRemotePath.trim() : '/小舟/笔记';
    const noteFilePath = noteDir.endsWith('/') ? `${noteDir}notes.json` : `${noteDir}/notes.json`;
    const noteFileUrl = joinDavUrl(config.serverUrl, noteFilePath);

    // 1. 确保笔记目录存在（软失败）
    await this.ensureDirAndParentsSoft(config, noteDir);

    // 2. 拉取远程笔记快照
    const localSnapshot = await this.noteRepository.getSnapshot();
    const remoteFetch = await this.execHttp(config, http.RequestMethod.GET, noteFileUrl, undefined);

    let mergedSnapshot: NoteSnapshot = localSnapshot;
    if (remoteFetch.code === 200 || remoteFetch.code === 207) {
      const parsed = this.parseNoteSnapshot(remoteFetch.body);
      if (parsed !== null) {
        mergedSnapshot = mergeNoteSnapshots(localSnapshot, parsed);
      }
      // 若解析失败，以本地为准（不中断）
    } else if (isFileNotFound(remoteFetch.code)) {
      mergedSnapshot = localSnapshot;
    } else if (remoteFetch.code === 401 || remoteFetch.code === 403) {
      return {
        success: false,
        message: `拉取远程笔记失败（HTTP ${remoteFetch.code}），请检查路径权限`
      };
    } else if (remoteFetch.code !== -1) {
      return { success: false, message: `拉取远程笔记失败（HTTP ${remoteFetch.code}）` };
    } else {
      return { success: false, message: `拉取远程笔记失败：${remoteFetch.body}` };
    }

    // 3. 本地写入合并结果
    await this.noteRepository.setSnapshot(mergedSnapshot);
    const noteBody = JSON.stringify(mergedSnapshot);

    // 4. 上传
    let putResult = await this.execHttp(config, http.RequestMethod.PUT, noteFileUrl, noteBody);
    if (putResult.code === 409) {
      // 强制建目录后重试
      const mkdirError = await this.ensureDirAndParentsHard(config, noteDir);
      if (mkdirError !== null) {
        return {
          success: false,
          message: `上传笔记失败：${mkdirError}。请手动在云盘建立「${noteDir}」目录后重试`
        };
      }
      putResult = await this.execHttp(config, http.RequestMethod.PUT, noteFileUrl, noteBody);
    }
    if (putResult.code !== 200 && putResult.code !== 201 && putResult.code !== 204) {
      return {
        success: false,
        message: `上传笔记失败（HTTP ${putResult.code}），本地已合并但未写入云端`
      };
    }

    return { success: true, message: '笔记已与云端合并并完成上传' };
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 目录创建策略（统一使用 rcp 发送 MKCOL）
  // ───────────────────────────────────────────────────────────────────────────

  /**
   * 软模式：MKCOL 失败时仅返回警告字符串，不中断主流程。
   * 适合在 PUT 前预置目录——若 MKCOL 失败，后面 PUT 会返回 409，
   * 届时再走硬模式。
   */
  private async ensureParentDirsSoft(
    config: WebDavConfig,
    remoteFilePath: string
  ): Promise<string | null> {
    const parents = listParentFolderPaths(remoteFilePath);
    return this.mkcolDirsSoft(config, parents);
  }

  private async ensureDirAndParentsSoft(
    config: WebDavConfig,
    remoteDirPath: string
  ): Promise<string | null> {
    const paths = listDirAndParentPaths(remoteDirPath);
    return this.mkcolDirsSoft(config, paths);
  }

  private async mkcolDirsSoft(
    config: WebDavConfig,
    paths: string[]
  ): Promise<string | null> {
    for (const p of paths) {
      const url = joinDavUrl(config.serverUrl, p);
      const res = await this.execMkcol(config, url);
      if (res.code === -1) {
        // 网络级失败才返回提示；HTTP 响应（含 405/409/403）按已存在处理
        return `创建目录 ${p} 时网络异常：${res.body}`;
      }
    }
    return null;
  }

  /**
   * 硬模式：仅在 PUT 返回 409 后重试时使用，此时必须确保目录存在，
   * 遇到真正的错误码才返回错误。
   */
  private async ensureParentDirsHard(
    config: WebDavConfig,
    remoteFilePath: string
  ): Promise<string | null> {
    const parents = listParentFolderPaths(remoteFilePath);
    return this.mkcolDirsHard(config, parents);
  }

  private async ensureDirAndParentsHard(
    config: WebDavConfig,
    remoteDirPath: string
  ): Promise<string | null> {
    const paths = listDirAndParentPaths(remoteDirPath);
    return this.mkcolDirsHard(config, paths);
  }

  private async mkcolDirsHard(
    config: WebDavConfig,
    paths: string[]
  ): Promise<string | null> {
    for (const p of paths) {
      const url = joinDavUrl(config.serverUrl, p);
      const res = await this.execMkcol(config, url);
      if (res.code === -1) {
        return `${p}：网络异常（${res.body}）`;
      }
      if (isMkcolSuccess(res.code)) {
        continue;
      }
      if (res.code === 403) {
        return `${p}：无权限创建目录（403）`;
      }
      // 其余未知码（如 500）打印警告但继续
    }
    return null;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // MKCOL 执行（通过 rcp，支持自定义 HTTP 方法）
  // ───────────────────────────────────────────────────────────────────────────

  /**
   * 使用 @kit.RemoteCommunicationKit (rcp) 发送 MKCOL 请求。
   * rcp 的 HttpMethod 类型支持任意字符串（含 'MKCOL'），
   * 而 @kit.NetworkKit 的 RequestMethod 枚举不包含 MKCOL。
   */
  private async execMkcol(
    config: WebDavConfig,
    url: string
  ): Promise<HttpExecResult> {
    const authHeader = makeBasicAuth(config.username.trim(), config.password);
    let session: rcp.Session | null = null;
    try {
      session = rcp.createSession();
      const headers: rcp.RequestHeaders = {
        'authorization': authHeader,
        'accept': '*/*',
        'user-agent': 'XiaozhouBrowser/1.0'
      };
      const request = new rcp.Request(url, 'MKCOL', headers);
      const response = await session.fetch(request);
      const code = response.statusCode;
      if (code === 0) {
        return { code: -1, body: 'HTTP 状态码为 0（网络不可用或 TLS 握手失败）' };
      }
      // MKCOL 响应通常没有 body，但解析一下以备调试
      let bodyText = '';
      if (response.body !== undefined && response.body !== null) {
        try {
          // rcp Response.body 是 ArrayBuffer
          const decoder = new util.TextDecoder('utf-8');
          bodyText = decoder.decodeWithStream(new Uint8Array(response.body));
          if (bodyText.length > 500) {
            bodyText = `${bodyText.substring(0, 500)}…`;
          }
        } catch (_) {
          bodyText = '(MKCOL 响应体无法解码)';
        }
      }
      return { code: code, body: bodyText };
    } catch (err) {
      const detail = exceptionToDetail(err as Object);
      return { code: -1, body: detail };
    } finally {
      if (session !== null) {
        session.close();
      }
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 解析
  // ───────────────────────────────────────────────────────────────────────────

  private parseBookmarkSnapshot(raw: string): BookmarkSnapshot | null {
    try {
      const obj = JSON.parse(raw) as BookmarkSnapshot;
      if (typeof obj.schemaVersion !== 'number') {
        return null;
      }
      if (!Array.isArray(obj.bookmarks) || !Array.isArray(obj.folders)) {
        return null;
      }
      return obj;
    } catch (_) {
      return null;
    }
  }

  private parseNoteSnapshot(raw: string): NoteSnapshot | null {
    try {
      const obj = JSON.parse(raw) as NoteSnapshot;
      if (typeof obj.schemaVersion !== 'number') {
        return null;
      }
      if (!Array.isArray(obj.notes) || !Array.isArray(obj.folders)) {
        return null;
      }
      return obj;
    } catch (_) {
      return null;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // HTTP 执行（@kit.NetworkKit，用于 GET/PUT/OPTIONS 等标准方法）
  // ───────────────────────────────────────────────────────────────────────────

  private async execHttp(
    config: WebDavConfig,
    method: http.RequestMethod,
    url: string,
    body: string | undefined
  ): Promise<HttpExecResult> {
    const httpRequest = http.createHttp();
    const authHeader = makeBasicAuth(config.username.trim(), config.password);
    const header: Record<string, string> = {
      'Authorization': authHeader,
      'Accept': '*/*',
      'User-Agent': 'XiaozhouBrowser/1.0'
    };
    if (body !== undefined && body.length > 0) {
      header['Content-Type'] = 'application/json; charset=utf-8';
    }
    try {
      const options: http.HttpRequestOptions = {
        method: method,
        header: header,
        connectTimeout: 15000,
        readTimeout: 60000,
        expectDataType: http.HttpDataType.STRING
      };
      if (body !== undefined && body.length > 0) {
        options.extraData = body;
      }
      const resp = await httpRequest.request(url, options);
      const code = resp.responseCode;
      if (code === 0) {
        return { code: -1, body: 'HTTP 状态码为 0（网络不可用或 TLS 握手失败）' };
      }
      const text = normalizeResponseBody(resp.result as Object);
      return { code: code, body: text };
    } catch (err) {
      const detail = exceptionToDetail(err as Object);
      return { code: -1, body: detail };
    } finally {
      httpRequest.destroy();
    }
  }
}
