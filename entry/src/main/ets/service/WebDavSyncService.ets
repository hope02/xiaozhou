import { http } from '@kit.NetworkKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { Bookmark, BookmarkFolder, BookmarkSnapshot } from '../model/Bookmark';
import { WebDavConfig } from '../model/WebDavConfig';
import { BookmarkRepository } from '../repository/BookmarkRepository';
import { NoteRepository } from '../repository/NoteRepository';
import { Note, NoteFolder, NoteSnapshot, NoteType, ImportMeta } from '../model/Note';
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
//   @kit.NetworkKit 的 http.RequestMethod 枚举仅含 8 种标准方法，不含 MKCOL/PROPFIND。
//   解决方案：使用 @kit.RemoteCommunicationKit (rcp) 发送 MKCOL/PROPFIND 请求。
//   rcp 的 HttpMethod 类型 = 标准 7 种 | (string & NonNullable<unknown>)，
//   编译期支持任意字符串，运行时正确发出请求。
//
// 远程存储结构（纯文件架构，无 json 索引）：
//   /小舟/书签/bookmarks.json                ← 书签快照（唯一 JSON）
//   /小舟/笔记/个人/XX.md                    ← 笔记内容文件（含 JSON frontmatter）
//   /小舟/笔记/YY.md                         ← 无文件夹的笔记直接在根目录
//   /小舟/笔记/工作/周记.txt
//
// 笔记纯文件架构（与 Obsidian 兼容）：
//   不使用 _index.json 或 notes.json。远程文件为纯正文，不写 frontmatter。
//   其他软件创建的含 frontmatter 的文件（JSON/YAML）会被正确解析。
//   匹配策略：标题+目录（同目录同标题 = 同一篇笔记，与 Obsidian 一致）。
//   文件名格式：{标题}.{扩展名}，无 id 后缀。
//   元数据（id、tags、type 等）仅保存在本地，不同步到远程。
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
// Internal types
// ─────────────────────────────────────────────────────────────────────────────

interface HttpExecResult {
  code: number;
  body: string;
}

/** PROPFIND 扫描到的远端文件条目 */
interface PropfindEntry {
  /** 文件名或目录名（如 "XX_a1b2.md" 或 "个人"） */
  name: string;
  /** 是否为目录 */
  isDirectory: boolean;
  /** 最后修改时间（epoch ms） */
  lastModified?: number;
}

/** 从 JSON frontmatter 解析出的笔记元数据 */
interface FrontmatterData {
  id?: string;
  type?: NoteType;
  title?: string;
  tags?: string[];
  favorite?: boolean;
  sourceUrl?: string;
  sourceTitle?: string;
  readProgress?: number;
  scrollPosition?: string;
  importMeta?: ImportMeta;
  createdAt?: number;
  updatedAt?: number;
  deletedFlag?: boolean;
}

/** 解析 frontmatter 后的完整结果 */
interface ParsedNoteFile {
  metadata: FrontmatterData;
  content: string;
}

/** 远程发现的笔记文件（PROPFIND + GET 解析后） */
interface RemoteNoteFile {
  /** 相对于笔记根目录的路径（如 "个人/XX_a1b2.md"） */
  relativePath: string;
  /** 解析后的 frontmatter 元数据 */
  metadata: FrontmatterData;
  /** 文件内容（不含 frontmatter） */
  content: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper functions
// ─────────────────────────────────────────────────────────────────────────────

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

/** 从服务器 URL 提取路径前缀（如 "https://dav.jianguoyun.com/dav/" → "/dav/"） */
function getServerPathPrefix(serverUrl: string): string {
  let url = serverUrl.trim();
  const schemeIdx = url.indexOf('://');
  if (schemeIdx >= 0) {
    url = url.substring(schemeIdx + 3);
  }
  const slashIdx = url.indexOf('/');
  if (slashIdx >= 0) {
    return url.substring(slashIdx);
  }
  return '/';
}

/** OPTIONS/GET 根路径可接受的状态码 */
function isDavRootReachable(code: number): boolean {
  return code === 200 || code === 204 || code === 207 || code === 404;
}

/**
 * 列出远程文件路径的所有父级目录，从浅到深。
 * 例如 /小舟/书签/bookmarks.json -> ['/小舟', '/小舟/书签']
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
 */
function isMkcolSuccess(code: number): boolean {
  return code === 201 || code === 200 || code === 204
    || code === 301 || code === 302
    || code === 405 || code === 409;
}

/** GET 文件时"文件不存在"的状态码（404 标准；409 坚果云父目录不存在） */
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

// ─────────────────────────────────────────────────────────────────────────────
// 文件名 / 路径 工具（笔记专用）
// ─────────────────────────────────────────────────────────────────────────────

/** 清理文件名中的非法字符 */
function sanitizeFileName(name: string): string {
  let s = name.trim();
  s = s.replace(/[/\\:*?"<>|]/g, '_');
  s = s.replace(/^[.\s]+|[.\s]+$/g, '');
  if (s.length > 200) {
    s = s.substring(0, 200);
  }
  if (s.length === 0) {
    s = 'untitled';
  }
  return s;
}

/**
 * 根据文件夹 id 向上回溯，计算相对目录路径。
 * "全部"（note_folder_root）是虚拟根，不产生目录层级。
 */
function computeFolderPath(folderId: string | undefined, folders: NoteFolder[]): string {
  if (folderId === undefined || folderId === null) {
    return '';
  }
  if (folderId === 'note_folder_root') {
    return '';
  }
  const folderMap = new Map<string, NoteFolder>();
  for (const f of folders) {
    folderMap.set(f.id, f);
  }
  const parts: string[] = [];
  let currentId: string | undefined = folderId;
  const visited = new Set<string>();
  while (currentId !== undefined && currentId !== null) {
    if (visited.has(currentId)) {
      break;
    }
    visited.add(currentId);
    if (currentId === 'note_folder_root') {
      break;
    }
    const folder = folderMap.get(currentId);
    if (folder === undefined) {
      break;
    }
    parts.unshift(sanitizeFileName(folder.name));
    currentId = folder.parentId;
  }
  return parts.join('/');
}

/** 根据笔记类型判断文件扩展名 */
function getNoteFileExtension(note: Note): string {
  if (note.type === 'import' && note.importMeta !== undefined && note.importMeta.fileFormat === 'txt') {
    return '.txt';
  }
  return '.md';
}

/**
 * 计算笔记的相对文件路径（基于笔记根目录）。
 * 格式：{文件夹路径}/{标题}.{扩展名}
 * 与 Obsidian 一致：同目录同标题唯一，无需 id 后缀。
 */
function computeNoteFilePath(note: Note, folders: NoteFolder[]): string {
  const folderPath = computeFolderPath(note.folderId, folders);
  const ext = getNoteFileExtension(note);
  const safeName = sanitizeFileName(note.title);
  const fileName = `${safeName}${ext}`;
  return folderPath.length > 0 ? `${folderPath}/${fileName}` : fileName;
}

/** 收集笔记目录下所有需要 MKCOL 的目录路径 */
function collectNoteDirPaths(noteDir: string, folders: NoteFolder[]): string[] {
  const dirSet = new Set<string>();
  for (const p of listDirAndParentPaths(noteDir)) {
    dirSet.add(p);
  }
  for (const folder of folders) {
    if (folder.id === 'note_folder_root') {
      continue;
    }
    const folderRelPath = computeFolderPath(folder.id, folders);
    if (folderRelPath.length > 0) {
      const fullPath = `${noteDir}/${folderRelPath}`;
      for (const p of listDirAndParentPaths(fullPath)) {
        dirSet.add(p);
      }
    }
  }
  return Array.from(dirSet);
}

// ─────────────────────────────────────────────────────────────────────────────
// JSON frontmatter 工具
// ─────────────────────────────────────────────────────────────────────────────

/** 从文件内容解析 JSON frontmatter。
 *  格式：第一行 ---，第二行 JSON 对象，第三行 ---，后面是正文。
 *  无 frontmatter 或格式无效时，整个内容作为正文返回。
 */
function parseFrontmatter(raw: string): ParsedNoteFile {
  const marker = '---';
  if (!raw.startsWith(marker)) {
    return { metadata: {}, content: raw };
  }
  // 跳过第一个 --- 和换行
  let pos = marker.length;
  if (pos < raw.length && raw.charCodeAt(pos) === 13) {
    pos++;
  }
  if (pos < raw.length && raw.charCodeAt(pos) === 10) {
    pos++;
  }
  // 找第二个 ---
  const secondMarkerIdx = raw.indexOf('\n' + marker, pos);
  if (secondMarkerIdx < 0) {
    return { metadata: {}, content: raw };
  }
  const jsonStr = raw.substring(pos, secondMarkerIdx).trim();
  const contentStart = secondMarkerIdx + marker.length + 1;
  const content = contentStart < raw.length ? raw.substring(contentStart) : '';
  if (jsonStr.length === 0) {
    return { metadata: {}, content: raw };
  }
  try {
    const parsed = JSON.parse(jsonStr) as FrontmatterData;
    return { metadata: parsed, content: content };
  } catch (_) {
    return { metadata: {}, content: raw };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PROPFIND XML 解析工具
// ─────────────────────────────────────────────────────────────────────────────

/** 去除 XML 标签中的命名空间前缀（如 <D:href> → <href>） */
function stripXmlNamespaces(xml: string): string {
  let result = xml;
  const prefixes = ['D:', 'd:', 'ns0:', 'ns1:', 'lp1:', 'S:', 's:'];
  for (const prefix of prefixes) {
    result = result.split('<' + prefix).join('<');
    result = result.split('</' + prefix).join('</');
  }
  return result;
}

/** HTTP 日期字符串 → epoch 毫秒 */
function httpDateToEpoch(dateStr: string): number | undefined {
  try {
    const d = new Date(dateStr);
    const ts = d.getTime();
    if (isNaN(ts)) {
      return undefined;
    }
    return ts;
  } catch (_) {
    return undefined;
  }
}

/**
 * 解析 PROPFIND XML 响应，提取文件和目录条目。
 * 跳过自引用条目（目录本身）。
 * serverPathPrefix: 服务器路径前缀，如 "/dav/"
 * noteDir: 笔记根目录，如 "/小舟/笔记"（用于计算相对路径）
 * currentDirUrl: 当前实际扫描的目录完整 URL（用于准确跳过自引用）
 */
function parsePropfindEntries(
  xml: string,
  serverPathPrefix: string,
  noteDir: string,
  currentDirUrl?: string
): PropfindEntry[] {
  const stripped = stripXmlNamespaces(xml);
  const entries: PropfindEntry[] = [];
  // 规范化 noteDir 用于比较
  const dirBase = noteDir.replace(/^\/+|\/+$/g, '');
  // 完整的目录路径（含服务器前缀），如 "/dav/小舟/笔记"
  const fullDirPath = serverPathPrefix.replace(/\/+$/, '') + '/' + dirBase;

  // 当前实际扫描的目录路径（含服务器前缀，不含尾部斜杠）
  let currentDirNormalized: string;
  if (currentDirUrl !== undefined) {
    // 从完整 URL 中提取路径部分，并 URL 解码
    let urlPath = currentDirUrl;
    const schemeIdx = urlPath.indexOf('://');
    if (schemeIdx >= 0) {
      urlPath = urlPath.substring(schemeIdx + 3);
      const slashIdx = urlPath.indexOf('/');
      if (slashIdx >= 0) {
        urlPath = urlPath.substring(slashIdx);
      } else {
        urlPath = '/';
      }
    }
    // URL 解码路径中的中文（如 %E5%... → 小）
    try {
      urlPath = decodeURIComponent(urlPath);
    } catch (_) { /* 保持原值 */ }
    currentDirNormalized = urlPath.replace(/\/+$/, '');
  } else {
    currentDirNormalized = fullDirPath;
  }

  const responsePattern = /<response>([\s\S]*?)<\/response>/gi;
  let matchResult: RegExpExecArray | null;

  while (true) {
    matchResult = responsePattern.exec(stripped);
    if (matchResult === null) {
      break;
    }
    const block = matchResult[1];

    // 提取 href
    const hrefMatch = block.match(/<href>([^<]*)<\/href>/i);
    if (hrefMatch === null || hrefMatch[1] === undefined) {
      continue;
    }
    let href = hrefMatch[1];

    // URL 解码
    try {
      href = decodeURIComponent(href);
    } catch (_) {
      // 保留原始值
    }

    // 清理路径（去掉尾部斜杠，用于准确比较）
    const cleanHref = href.replace(/\/+$/, '');

    // 跳过自引用（href 与当前扫描目录相同）
    if (cleanHref === currentDirNormalized) {
      continue;
    }
    // 也跳过 noteDir 本身（首次扫描时的自引用）
    if (cleanHref === fullDirPath || cleanHref === '/' + dirBase || cleanHref === dirBase) {
      continue;
    }

    // 从 href 中提取相对于 noteDir 的路径
    let relPath = '';
    if (cleanHref.startsWith(fullDirPath + '/')) {
      relPath = cleanHref.substring(fullDirPath.length + 1);
    } else if (cleanHref.startsWith('/' + dirBase + '/')) {
      relPath = cleanHref.substring(dirBase.length + 2);
    } else {
      // 尝试直接从路径末尾取
      const lastSlash = cleanHref.lastIndexOf('/');
      relPath = lastSlash >= 0 ? cleanHref.substring(lastSlash + 1) : cleanHref;
    }

    if (relPath.length === 0) {
      continue;
    }

    // 是否为目录
    const isDirectory = /<collection\s*\/>/i.test(block) || href.endsWith('/');

    // 对于文件，name 就是文件名；对于目录，name 是目录名
    // relPath 可能包含子路径（如 "个人/XX.md"），但对于 depth:1 应该只有直接子项
    const name = relPath.indexOf('/') >= 0
      ? relPath.substring(relPath.lastIndexOf('/') + 1)
      : relPath;

    // 提取最后修改时间
    let lastModified: number | undefined;
    const lmMatch = block.match(/<getlastmodified>([^<]*)<\/getlastmodified>/i);
    if (lmMatch !== null && lmMatch[1] !== undefined) {
      lastModified = httpDateToEpoch(lmMatch[1]);
    }

    entries.push({ name, isDirectory, lastModified });
  }

  return entries;
}

// ─────────────────────────────────────────────────────────────────────────────
// 合并工具
// ─────────────────────────────────────────────────────────────────────────────

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

/**
 * 合并 NoteFolder 列表。
 * 先按 id 匹配，再按 name+parentId 匹配（防止同文件夹不同 id 导致重复）。
 * 匹配到的保留本地 id，按 updatedAt 取最新版本。
 */
function mergeNoteFolders(local: NoteFolder[], remote: NoteFolder[]): NoteFolder[] {
  const result: NoteFolder[] = [];

  // 1. 按 id 精确匹配
  const remoteById = new Map<string, NoteFolder>();
  for (const f of remote) {
    remoteById.set(f.id, f);
  }
  const matchedRemoteIds = new Set<string>();

  for (const lf of local) {
    const rf = remoteById.get(lf.id);
    if (rf !== undefined) {
      matchedRemoteIds.add(rf.id);
      // 同 id：取更新的版本，保留本地 id
      if (rf.updatedAt > lf.updatedAt) {
        const merged: NoteFolder = {
          id: lf.id,
          name: rf.name,
          parentId: rf.parentId,
          icon: rf.icon,
          color: rf.color,
          updatedAt: rf.updatedAt,
        };
        result.push(merged);
      } else {
        result.push(lf);
      }
    } else {
      result.push(lf);
    }
  }

  // 2. 未匹配 id 的远程文件夹，按 name+parentId 查找本地是否已有同名文件夹
  const localByNameKey = new Map<string, NoteFolder>();
  for (const lf of result) {
    localByNameKey.set(lf.name + '@' + (lf.parentId ?? ''), lf);
  }

  for (const rf of remote) {
    if (matchedRemoteIds.has(rf.id)) {
      continue;
    }
    const nameKey = rf.name + '@' + (rf.parentId ?? '');
    const existing = localByNameKey.get(nameKey);
    if (existing !== undefined) {
      // 同名同位置：已通过本地文件夹包含，跳过（避免重复）
      continue;
    }
    // 远程独有：加入结果
    result.push(rf);
    localByNameKey.set(nameKey, rf);
  }

  return result;
}

/**
 * 根据目录相对路径，查找或创建对应的 NoteFolder 链。
 * 例如 dirPath="学习/编程" 会确保 "学习" 和 "编程" 两个 NoteFolder 存在并正确关联。
 * 返回最深层文件夹的 id（若无目录路径则返回 undefined）。
 *
 * 注意：顶层文件夹的 parentId 必须是 'note_folder_root'，
 * 因为 NoteFolderManagerPage 通过 childrenOf('note_folder_root') 来展示文件夹树。
 */
const NOTE_FOLDER_ROOT_ID = 'note_folder_root';

function findOrCreateFolderByPath(
  dirPath: string,
  existingFolders: NoteFolder[],
  newFolders: NoteFolder[]
): string | undefined {
  if (dirPath.length === 0) {
    return undefined;
  }
  const segments = dirPath.split('/').filter((s: string) => s.length > 0);
  if (segments.length === 0) {
    return undefined;
  }

  const allFolders = existingFolders.concat(newFolders);
  const folderByName = new Map<string, NoteFolder>();
  for (const f of allFolders) {
    folderByName.set(f.name + '@' + (f.parentId ?? ''), f);
  }

  let parentId: string = NOTE_FOLDER_ROOT_ID;
  for (const seg of segments) {
    const key = seg + '@' + parentId;
    let folder = folderByName.get(key);
    if (folder === undefined) {
      // 创建新文件夹（顶层 parentId = 'note_folder_root'，子目录 parentId = 父文件夹 id）
      const now = Date.now();
      const id = `folder_${now}_${Math.random().toString(36).substring(2, 8)}`;
      const newFolder: NoteFolder = {
        id: id,
        name: seg,
        parentId: parentId,
        updatedAt: now,
      };
      newFolders.push(newFolder);
      folderByName.set(key, newFolder);
      folder = newFolder;
    }
    parentId = folder.id;
  }
  return parentId;
}

/** 从文件名提取标题（去掉 id 后缀和扩展名） */
function titleFromFileName(fileName: string): string {
  // 去掉扩展名
  const dotIdx = fileName.lastIndexOf('.');
  let baseName = dotIdx >= 0 ? fileName.substring(0, dotIdx) : fileName;
  // 去掉 id 后缀（格式：{标题}_{id前8位}）
  const underscoreIdx = baseName.lastIndexOf('_');
  if (underscoreIdx > 0) {
    const possibleId = baseName.substring(underscoreIdx + 1);
    // id 后缀通常是 8 位十六进制
    if (/^[0-9a-f]{6,12}$/i.test(possibleId)) {
      baseName = baseName.substring(0, underscoreIdx);
    }
  }
  return baseName.length > 0 ? baseName : fileName;
}

/** 生成唯一 id */
function generateId(): string {
  return `${Date.now()}_${Math.random().toString(36).substring(2, 10)}`;
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
    const bookmarkResult = await this.syncBookmarks(config);
    if (!bookmarkResult.success) {
      return bookmarkResult;
    }

    if (config.syncNotesEnabled && this.noteRepository !== null) {
      const noteResult = await this.syncNotes(config);
      if (!noteResult.success) {
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
  // syncBookmarks（书签仍为单一 JSON 快照）
  // ───────────────────────────────────────────────────────────────────────────

  private async syncBookmarks(config: WebDavConfig): Promise<SyncExecutionResult> {
    const bookmarkUrl = joinDavUrl(config.serverUrl, config.remotePath);
    const localBookmarks = await this.bookmarkRepository.getSnapshot();

    // 1. 确保父目录存在（软失败）
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

    // 4. 上传
    let putResult = await this.execHttp(config, http.RequestMethod.PUT, bookmarkUrl, bookmarkBody);
    if (putResult.code === 409) {
      const mkdirError = await this.ensureParentDirsHard(config, config.remotePath);
      if (mkdirError !== null) {
        return {
          success: false,
          message: `上传书签失败：${mkdirError}。请手动在云盘建立「小舟/书签」文件夹后重试`
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
  // syncNotes（纯文件架构：PROPFIND + JSON frontmatter）
  //
  // 远程结构（无 json 索引文件）：
  //   /小舟/笔记/个人/XX_a1b2.md  ← 含 JSON frontmatter
  //   /小舟/笔记/YY_c3d4.md       ← 无文件夹的笔记直接在根目录
  //   /小舟/笔记/其他软件.md       ← 其他软件创建的文件（无 frontmatter）自动导入
  //
  // 同步流程：
  //   1. PROPFIND 递归扫描远程笔记目录，发现所有 .md/.txt 文件
  //   2. GET 每个远程文件，解析 JSON frontmatter
  //   3. 按 id 匹配本地笔记，按 updatedAt 合并
  //   4. 远程独有的文件 → 下载并创建本地笔记
  //   5. 本地独有的笔记 → 上传带 frontmatter 的文件
  //   6. MKCOL 建目录
  //   7. 上传变更的笔记文件
  // ───────────────────────────────────────────────────────────────────────────

  private async syncNotes(config: WebDavConfig): Promise<SyncExecutionResult> {
    if (this.noteRepository === null) {
      return { success: false, message: '笔记仓库未初始化' };
    }

    const noteDir = config.noteRemotePath.trim().length > 0 ? config.noteRemotePath.trim() : '/小舟/笔记';

    // ── 0. 预建笔记根目录及其父目录（确保 PROPFIND 能扫描到）──────────────────
    await this.ensureDirAndParentsSoft(config, noteDir);

    // ── 1. 获取本地数据 ────────────────────────────────────────────────────────
    const localSnapshot = await this.noteRepository.getSnapshot();
    const localNoteMap = new Map<string, Note>();
    for (const n of localSnapshot.notes) {
      localNoteMap.set(n.id, n);
    }

    // ── 2. PROPFIND 递归扫描远程目录 ──────────────────────────────────────────
    const remoteFiles = new Map<string, RemoteNoteFile>();
    const remoteFolders: NoteFolder[] = [];
    await this.scanRemoteDirectory(config, noteDir, '', remoteFiles, remoteFolders);

    // ── 3. 合并文件夹 ─────────────────────────────────────────────────────────
    const mergedFolders = mergeNoteFolders(localSnapshot.folders, remoteFolders);
    const mergedFolderMap = new Map<string, NoteFolder>();
    for (const f of mergedFolders) {
      mergedFolderMap.set(f.id, f);
    }

    // ── 4. 合并笔记 + 确定同步方向 ─────────────────────────────────────────────
    // 唯一匹配策略：标题+目录（与 Obsidian 一致，同目录同标题 = 同一篇笔记）
    const mergedNoteMap = new Map<string, Note>();
    const notesToUpload: Note[] = [];
    const newFoldersFromMerge: NoteFolder[] = [];

    // 构建本地笔记匹配表："标题@目录路径" → localNote
    const localMatchMap = new Map<string, Note>();
    for (const localNote of localSnapshot.notes) {
      const dirPath = computeFolderPath(localNote.folderId, localSnapshot.folders);
      const key = (localNote.title ?? '') + '@' + dirPath;
      if (key.length > 1 && !localMatchMap.has(key)) {
        localMatchMap.set(key, localNote);
      }
    }

    // 已匹配的本地笔记 id（避免重复匹配）
    const matchedLocalIds = new Set<string>();

    // ── 4a. 遍历远程文件，与本地笔记匹配 ─────────────────────────────────────
    const remoteFilesArr: string[] = [];
    remoteFiles.forEach((_rf: RemoteNoteFile, rp: string) => remoteFilesArr.push(rp));

    for (const rp of remoteFilesArr) {
      const rf = remoteFiles.get(rp);
      if (rf === undefined) continue;

      // 计算远程文件的目录路径和标题
      const lastSlash = rp.lastIndexOf('/');
      const dirPath = lastSlash >= 0 ? rp.substring(0, lastSlash) : '';
      const remoteTitle = rf.metadata.title ?? titleFromFileName(rp.substring(lastSlash >= 0 ? lastSlash + 1 : 0));
      const remoteKey = remoteTitle + '@' + dirPath;

      const localMatch = localMatchMap.get(remoteKey);

      if (localMatch !== undefined && !matchedLocalIds.has(localMatch.id)) {
        // ── 匹配成功：同目录同标题 → 同一篇笔记 ───────────────────────────────
        matchedLocalIds.add(localMatch.id);
        const remoteUpdatedAt = rf.metadata.updatedAt ?? 0;

        if (localMatch.updatedAt >= remoteUpdatedAt) {
          // 本地版本更新或相同 → 保留本地
          mergedNoteMap.set(localMatch.id, localMatch);
          if (localMatch.updatedAt > remoteUpdatedAt && !localMatch.deletedFlag) {
            notesToUpload.push(localMatch);
          }
        } else {
          // 远程版本更新 → 从远程构建笔记，但使用本地 id 保持一致性
          const note = remoteNoteFileToNote(rf, mergedFolders, newFoldersFromMerge);
          note.id = localMatch.id;
          mergedNoteMap.set(note.id, note);
        }
      } else {
        // ── 远程独有 → 下载创建本地笔记 ────────────────────────────────────────
        const note = remoteNoteFileToNote(rf, mergedFolders, newFoldersFromMerge);
        mergedNoteMap.set(note.id, note);
      }
    }

    // ── 4b. 处理仅本地有的笔记（远程没有匹配）────────────────────────────────
    for (const localNote of localSnapshot.notes) {
      if (matchedLocalIds.has(localNote.id)) continue;
      // 仅本地有 → 保留并上传
      mergedNoteMap.set(localNote.id, localNote);
      if (!localNote.deletedFlag) {
        notesToUpload.push(localNote);
      }
    }

    // 将合并过程中新建的文件夹加入合并结果
    for (const nf of newFoldersFromMerge) {
      const nameKey = nf.name + '@' + (nf.parentId ?? '');
      const exists = mergedFolders.some((f: NoteFolder) => (f.name + '@' + (f.parentId ?? '')) === nameKey);
      if (!exists) {
        mergedFolders.push(nf);
      }
    }

    // ── 5. 保存合并结果到本地 ──────────────────────────────────────────────────
    const mergedNotes: Note[] = [];
    mergedNoteMap.forEach((v: Note) => mergedNotes.push(v));

    const mergedSnapshot: NoteSnapshot = {
      schemaVersion: localSnapshot.schemaVersion,
      notes: mergedNotes,
      folders: mergedFolders,
    };
    await this.noteRepository.setSnapshot(mergedSnapshot);

    // ── 6. MKCOL 建目录（确保远端所有文件夹路径都存在）───────────────────────────
    const dirsNeeded = collectNoteDirPaths(noteDir, mergedFolders);
    let dirError: string | null = null;
    for (const dirPath of dirsNeeded) {
      const dirUrl = joinDavUrl(config.serverUrl, dirPath);
      const mkcolResult = await this.execMkcol(config, dirUrl);
      if (mkcolResult.code === -1) {
        dirError = `创建目录 ${dirPath} 时网络异常`;
        break;
      }
      if (mkcolResult.code === 403) {
        dirError = `无权限创建目录 ${dirPath}（403）`;
        break;
      }
      // 其他状态码（201/405/409 等）均视为成功或已存在
    }

    // ── 7. 上传需要同步的笔记文件（纯正文，不写 frontmatter，与 Obsidian 兼容）──────
    const uploadDedupeMap = new Map<string, Note>();
    for (const note of notesToUpload) {
      uploadDedupeMap.set(note.id, note);
    }

    let uploadedCount = 0;
    let uploadFailCount = 0;
    const uploadList: Note[] = [];
    uploadDedupeMap.forEach((v: Note) => uploadList.push(v));
    for (const note of uploadList) {
      const filePath = computeNoteFilePath(note, mergedFolders);
      const fileUrl = joinDavUrl(config.serverUrl, `${noteDir}/${filePath}`);
      // 只上传纯正文，不写 frontmatter（与 Obsidian 等其他软件兼容）
      const fileBody = note.contentPlain !== undefined && note.contentPlain.length > 0
        ? note.contentPlain
        : note.content;
      const contentType = filePath.endsWith('.txt') ? 'text/plain; charset=utf-8' : 'text/markdown; charset=utf-8';

      let putResult = await this.execHttp(config, http.RequestMethod.PUT, fileUrl, fileBody, contentType);
      if (putResult.code === 409) {
        // 父目录可能不存在，硬模式重试
        const folderRelPath = computeFolderPath(note.folderId, mergedFolders);
        const parentDir = folderRelPath.length > 0 ? `${noteDir}/${folderRelPath}` : noteDir;
        const mkdirError = await this.ensureDirAndParentsHard(config, parentDir);
        if (mkdirError !== null) {
          uploadFailCount++;
          continue;
        }
        putResult = await this.execHttp(config, http.RequestMethod.PUT, fileUrl, fileBody, contentType);
      }
      if (putResult.code === 200 || putResult.code === 201 || putResult.code === 204) {
        uploadedCount++;
      } else {
        uploadFailCount++;
      }
    }

    const downloadedCount = mergedNotes.filter((n: Note) => {
      if (localNoteMap.has(n.id)) return false;
      return true;
    }).length;

    // 构建结果消息
    let message = `笔记已同步（上传 ${uploadedCount} 篇，下载 ${downloadedCount} 篇）`;
    if (dirError !== null) {
      message += `；⚠️ 目录创建异常：${dirError}`;
    }
    if (uploadFailCount > 0) {
      message += `；⚠️ ${uploadFailCount} 篇笔记上传失败`;
    }

    return { success: true, message: message };
  }

  // ───────────────────────────────────────────────────────────────────────────
  // PROPFIND 递归扫描远程笔记目录
  // ───────────────────────────────────────────────────────────────────────────

  private async scanRemoteDirectory(
    config: WebDavConfig,
    noteDir: string,
    pathPrefix: string,
    result: Map<string, RemoteNoteFile>,
    remoteFolders: NoteFolder[]
  ): Promise<void> {
    const dirUrl = joinDavUrl(config.serverUrl, pathPrefix.length > 0 ? `${noteDir}/${pathPrefix}` : noteDir);
    // 去掉 pathPrefix 末尾的 /
    const cleanPrefix = pathPrefix.endsWith('/') ? pathPrefix.substring(0, pathPrefix.length - 1) : pathPrefix;

    const propfindResult = await this.execPropfind(config, dirUrl, 1);
    if (propfindResult.code !== 207) {
      return;
    }

    const serverPathPrefix = getServerPathPrefix(config.serverUrl);
    // 传入 dirUrl（不含协议头），让 parsePropfindEntries 能准确跳过当前目录的自引用条目
    const entries = parsePropfindEntries(propfindResult.body, serverPathPrefix, noteDir, dirUrl);

    for (const entry of entries) {
      const entryPath = cleanPrefix.length > 0 ? `${cleanPrefix}/${entry.name}` : entry.name;

      if (entry.isDirectory) {
        // 为远程目录创建/匹配 NoteFolder
        const parentDirPath = cleanPrefix.length > 0 ? cleanPrefix : '';
        const folderId = findOrCreateFolderByPath(entryPath, [], remoteFolders);
        // 递归扫描子目录
        await this.scanRemoteDirectory(config, noteDir, entryPath + '/', result, remoteFolders);
      } else if (entry.name.endsWith('.md') || entry.name.endsWith('.txt')) {
        // GET 文件内容
        const fileUrl = joinDavUrl(config.serverUrl, `${noteDir}/${entryPath}`);
        const fetchResult = await this.execHttp(config, http.RequestMethod.GET, fileUrl, undefined);
        if (fetchResult.code !== 200 && fetchResult.code !== 207) {
          continue;
        }
        const parsed = parseFrontmatter(fetchResult.body);
        // 如果 frontmatter 无 id，生成一个
        if (parsed.metadata.id === undefined || parsed.metadata.id.length === 0) {
          parsed.metadata.id = generateId();
        }
        if (parsed.metadata.title === undefined || parsed.metadata.title.length === 0) {
          parsed.metadata.title = titleFromFileName(entry.name);
        }
        if (parsed.metadata.createdAt === undefined) {
          parsed.metadata.createdAt = entry.lastModified ?? Date.now();
        }
        if (parsed.metadata.updatedAt === undefined) {
          parsed.metadata.updatedAt = entry.lastModified ?? Date.now();
        }
        result.set(entryPath, {
          relativePath: entryPath,
          metadata: parsed.metadata,
          content: parsed.content,
        });
      }
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 目录创建策略（统一使用 rcp 发送 MKCOL）
  // ───────────────────────────────────────────────────────────────────────────

  /** 软模式：MKCOL 失败时仅返回警告，不中断主流程 */
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
        return `创建目录 ${p} 时网络异常：${res.body}`;
      }
    }
    return null;
  }

  /** 硬模式：PUT 返回 409 后重试时使用 */
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
    }
    return null;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // MKCOL 执行（通过 rcp）
  // ───────────────────────────────────────────────────────────────────────────

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
      let bodyText = '';
      if (response.body !== undefined && response.body !== null) {
        try {
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
  // PROPFIND 执行（通过 rcp）
  // ───────────────────────────────────────────────────────────────────────────

  private async execPropfind(
    config: WebDavConfig,
    url: string,
    depth: number
  ): Promise<HttpExecResult> {
    const authHeader = makeBasicAuth(config.username.trim(), config.password);
    let session: rcp.Session | null = null;
    try {
      session = rcp.createSession();
      const headers: rcp.RequestHeaders = {
        'authorization': authHeader,
        'accept': 'application/xml, */*',
        'user-agent': 'XiaozhouBrowser/1.0',
        'depth': depth.toString(),
      };
      const request = new rcp.Request(url, 'PROPFIND', headers);
      const response = await session.fetch(request);
      const code = response.statusCode;
      if (code === 0) {
        return { code: -1, body: 'HTTP 状态码为 0（网络不可用或 TLS 握手失败）' };
      }
      let bodyText = '';
      if (response.body !== undefined && response.body !== null) {
        try {
          const decoder = new util.TextDecoder('utf-8');
          bodyText = decoder.decodeWithStream(new Uint8Array(response.body));
        } catch (_) {
          bodyText = '(PROPFIND 响应体无法解码)';
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

  // ───────────────────────────────────────────────────────────────────────────
  // HTTP 执行（@kit.NetworkKit，用于 GET/PUT/OPTIONS 等标准方法）
  // ───────────────────────────────────────────────────────────────────────────

  private async execHttp(
    config: WebDavConfig,
    method: http.RequestMethod,
    url: string,
    body: string | undefined,
    contentType?: string
  ): Promise<HttpExecResult> {
    const httpRequest = http.createHttp();
    const authHeader = makeBasicAuth(config.username.trim(), config.password);
    const header: Record<string, string> = {
      'Authorization': authHeader,
      'Accept': '*/*',
      'User-Agent': 'XiaozhouBrowser/1.0'
    };
    if (body !== undefined && body.length > 0) {
      header['Content-Type'] = contentType !== undefined ? contentType : 'application/json; charset=utf-8';
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

// ─────────────────────────────────────────────────────────────────────────────
// 远程文件 → 本地笔记转换
// ─────────────────────────────────────────────────────────────────────────────

/** 从远程笔记文件构建 Note 对象 */
function remoteNoteFileToNote(rf: RemoteNoteFile, folders: NoteFolder[], newFolders: NoteFolder[]): Note {
  const meta = rf.metadata;
  const isTxt = rf.relativePath.endsWith('.txt');
  // 从目录路径推断 folderId（新建的文件夹收集到 newFolders）
  const lastSlash = rf.relativePath.lastIndexOf('/');
  const dirPath = lastSlash >= 0 ? rf.relativePath.substring(0, lastSlash) : '';
  const folderId = findOrCreateFolderByPath(dirPath, folders, newFolders);

  const note: Note = {
    id: meta.id ?? generateId(),
    type: meta.type ?? (isTxt ? 'import' : 'manual'),
    title: meta.title ?? titleFromFileName(rf.relativePath),
    content: rf.content,
    contentPlain: isTxt ? rf.content : undefined,
    sourceUrl: meta.sourceUrl,
    sourceTitle: meta.sourceTitle,
    tags: meta.tags ?? [],
    folderId: folderId,
    isFavorite: meta.favorite ?? false,
    importMeta: meta.importMeta,
    readProgress: meta.readProgress ?? 0,
    scrollPosition: meta.scrollPosition,
    createdAt: meta.createdAt ?? Date.now(),
    updatedAt: meta.updatedAt ?? Date.now(),
    deletedFlag: meta.deletedFlag ?? false,
  };
  return note;
}
