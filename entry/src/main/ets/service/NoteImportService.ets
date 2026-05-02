import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
// zlib is loaded lazily in parseZip() to avoid crash on devices without the module
import { Note, ImportMeta, Chapter, NoteType } from '../model/Note';
import { base64Encode } from '../util/Base64Util';

const CHUNK_SIZE: number = 1024 * 512; // 512KB per chunk
const MAX_FILE_SIZE: number = 1024 * 1024 * 20; // 20MB limit
const DEFAULT_CACHE_DIR: string = '/data/storage/el2/base/cache/imports';

export interface ImportResult {
  note: Note;
  meta: ImportMeta;
}

export interface ImportProgress {
  stage: 'reading' | 'parsing' | 'extracting' | 'done';
  percent: number;
  message: string;
}

interface OpfContent {
  title: string;
  author: string;
  spine: string[];
  manifest: Record<string, string>;
  coverId: string;
}

interface FileInfo {
  name: string;
  size: number;
  type: string;
}

interface ZlibModule {
  default?: ZlibModule;
  decompressFile?: (src: string, dest: string) => Promise<void>;
}

export class NoteImportService {
  private progressCallback: ((progress: ImportProgress) => void) | null = null;
  private cacheDir: string;

  private readonly chapterPatterns: RegExp[] = [
    /^第[一二三四五六七八九十百千万零\d]+章\s*.*$/m,
    /^第[一二三四五六七八九十百千万零\d]+节\s*.*$/m,
    /^(?:Chapter|CHAPTER|Sec|SEC)\s+\d+[\s:：].*$/m,
    /^\d+\s*[、.．]\s*.*$/m,
    /^【.*】$/m
  ];

  constructor(progressCallback?: (progress: ImportProgress) => void, cacheDir?: string) {
    if (progressCallback) {
      this.progressCallback = progressCallback;
    }
    this.cacheDir = cacheDir ?? DEFAULT_CACHE_DIR;
  }

  setProgressCallback(callback: (progress: ImportProgress) => void): void {
    this.progressCallback = callback;
  }

  private emitProgress(stage: 'reading' | 'parsing' | 'extracting' | 'done', percent: number, message: string): void {
    if (this.progressCallback) {
      const progress: ImportProgress = { stage, percent, message };
      this.progressCallback(progress);
    }
  }

  // ----- TXT Import -----

  async importTxt(uri: string, originalFileName: string): Promise<ImportResult> {
    this.emitProgress('reading', 0, '正在读取文件...');
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const stat = fs.statSync(uri);
    const fileSize = stat.size;

    if (fileSize > MAX_FILE_SIZE) {
      fs.closeSync(file);
      throw new Error('文件过大，请导入小于20MB的文件');
    }

    // Read first bytes to detect encoding
    const headBuf = new ArrayBuffer(4096);
    const bytesRead = fs.readSync(file.fd, headBuf, { offset: 0, length: Math.min(4096, fileSize) });
    const encoding = this.detectEncoding(new Uint8Array(headBuf, 0, bytesRead));

    this.emitProgress('reading', 30, '正在读取全文...');
    const content = await this.readTextFile(file.fd, fileSize, encoding);
    fs.closeSync(file);

    this.emitProgress('parsing', 60, '正在解析章节...');
    const chapters = this.splitChapters(content);
    const title = this.extractTitle(content, originalFileName);
    const characterCount = content.length;
    const plainContent = content.replace(/[#*`>\-\[\]()!]/g, '');

    const chapterCount = chapters.length;
    const importMeta: ImportMeta = {
      originalFileName: originalFileName,
      fileFormat: 'txt',
      chapterCount: chapterCount,
      chapters: chapters,
      characterCount: characterCount
    };

    const now = Date.now();
    const note: Note = {
      id: 'note_' + now + '_' + Math.random().toString(36).substring(2, 8),
      type: 'import',
      title: title,
      content: content,
      contentPlain: plainContent.substring(0, 300),
      tags: ['导入文档'],
      isFavorite: false,
      importMeta: importMeta,
      readProgress: 0,
      createdAt: now,
      updatedAt: now,
      deletedFlag: false
    };

    this.emitProgress('done', 100, '导入完成');
    return { note, meta: importMeta };
  }

  private detectEncoding(head: Uint8Array): string {
    // BOM detection
    if (head.length >= 3 && head[0] === 0xEF && head[1] === 0xBB && head[2] === 0xBF) {
      return 'utf-8';
    }
    if (head.length >= 2 && head[0] === 0xFF && head[1] === 0xFE) {
      return 'utf-16le';
    }
    if (head.length >= 2 && head[0] === 0xFE && head[1] === 0xFF) {
      return 'utf-16be';
    }

    // Check if valid UTF-8
    let isUtf8 = true;
    let i = 0;
    while (i < head.length) {
      if (head[i] < 0x80) {
        i++;
      } else if (head[i] >= 0xC0 && head[i] < 0xE0) {
        if (i + 1 >= head.length || (head[i + 1] & 0xC0) !== 0x80) { isUtf8 = false; break; }
        i += 2;
      } else if (head[i] >= 0xE0 && head[i] < 0xF0) {
        if (i + 2 >= head.length || (head[i + 1] & 0xC0) !== 0x80 || (head[i + 2] & 0xC0) !== 0x80) { isUtf8 = false; break; }
        i += 3;
      } else if (head[i] >= 0xF0 && head[i] < 0xF8) {
        if (i + 3 >= head.length || (head[i + 1] & 0xC0) !== 0x80 || (head[i + 2] & 0xC0) !== 0x80 || (head[i + 3] & 0xC0) !== 0x80) { isUtf8 = false; break; }
        i += 4;
      } else {
        isUtf8 = false;
        break;
      }
    }

    if (isUtf8) {
      return 'utf-8';
    }

    // GBK detection heuristic: common GBK bytes with high bit set
    let gbkScore = 0;
    for (let j = 0; j < Math.min(head.length, 2000); j++) {
      if (head[j] >= 0x81 && head[j] <= 0xFE) {
        gbkScore++;
        j++; // GBK uses two bytes
      }
    }
    if (gbkScore > 10) {
      return 'gbk';
    }

    return 'utf-8';
  }

  private async readTextFile(fd: number, fileSize: number, _encoding: string): Promise<string> {
    // HarmonyOS fileIo reads as UTF-8 by default
    // For GBK, we'd need an external library; fallback to reading as-is
    const chunks: string[] = [];
    let offset = 0;
    while (offset < fileSize) {
      const chunkSize = Math.min(CHUNK_SIZE, fileSize - offset);
      const buf = new ArrayBuffer(chunkSize);
      fs.readSync(fd, buf, { offset: offset, length: chunkSize });
      const textDecoder = new util.TextDecoder('utf-8', { ignoreBOM: false });
      const text = textDecoder.decode(new Uint8Array(buf), { stream: false });
      chunks.push(text);
      offset += chunkSize;
      const percent = Math.min(Math.floor((offset / fileSize) * 30) + 30, 60);
      this.emitProgress('reading', percent, '正在读取...');
    }
    return chunks.join('');
  }

  private splitChapters(content: string): Chapter[] {
    const lines = content.split('\n');
    const chapters: Chapter[] = [];
    let chIndex = 0;
    let buffer: string[] = [];

    const flushBuffer = (): void => {
      if (buffer.length > 0) {
        // Empty line separated chapters
        chIndex++;
        const title = buffer[0].trim().substring(0, 100) || '第' + chIndex + '章';
        chapters.push({
          title: title,
          anchor: 'ch_' + chIndex,
          level: 1
        });
        buffer = [];
      }
    };

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      const match = this.chapterPatterns.find(p => p.test(line));

      if (match) {
        flushBuffer();
        chIndex++;
        chapters.push({
          title: line.substring(0, 100),
          anchor: 'ch_' + chIndex,
          level: 1
        });
      } else if (line.length === 0 && buffer.length > 0) {
        // Empty line after content could be a chapter separator
        // Only flush if there's substantial content in the buffer
        if (buffer.length >= 3) {
          flushBuffer();
        }
      } else {
        buffer.push(line);
      }
    }

    // Don't flush remaining buffer as a chapter if we already have chapters
    // (means the last bit of content after the final chapter)

    if (chapters.length === 0) {
      // No chapter markers found, treat entire content as one chapter
      chapters.push({
        title: '全文',
        anchor: 'ch_1',
        level: 1
      });
    }

    return chapters;
  }

  private extractTitle(content: string, originalFileName: string): string {
    const lines = content.split('\n');
    // First non-empty line as title
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.length > 0 && trimmed.length < 100) {
        // Remove common prefix patterns
        return trimmed.replace(/^[#\s]*/, '');
      }
    }
    // Fall back to file name without extension
    return originalFileName.replace(/\.(txt|epub)$/i, '');
  }

  // ----- EPUB Import -----

  async importEpub(uri: string, originalFileName: string): Promise<ImportResult> {
    this.emitProgress('reading', 0, '正在打开EPUB文件...');

    // EPUB is a ZIP file; use zlib to decompress
    const stat = fs.statSync(uri);
    const fileSize = stat.size;

    if (fileSize > MAX_FILE_SIZE) {
      throw new Error('文件过大，请导入小于20MB的文件');
    }

    this.emitProgress('extracting', 20, '正在解压EPUB...');
    const zipEntries = await this.parseZip(uri);

    // Parse container.xml to find OPF
    this.emitProgress('extracting', 30, '正在解析元数据...');
    const containerXml = this.getZipEntry(zipEntries, 'META-INF/container.xml');
    if (!containerXml) {
      throw new Error('无效的EPUB文件：找不到container.xml');
    }
    const opfPath = this.extractOpfPath(containerXml);
    if (!opfPath) {
      throw new Error('无效的EPUB文件：无法解析container.xml');
    }

    // Parse OPF
    const opfContent = this.getZipEntry(zipEntries, opfPath);
    if (!opfContent) {
      throw new Error('无效的EPUB文件：找不到OPF文件');
    }

    const baseDir = opfPath.substring(0, opfPath.lastIndexOf('/') + 1);
    const opfInfo = this.parseOpf(opfContent);

    // Read chapters in order
    this.emitProgress('extracting', 50, '正在解析章节...');
    const chapters: Chapter[] = [];
    const contentParts: string[] = [];
    let chIndex = 0;

    for (const href of opfInfo.spine) {
      const fullPath = baseDir + href;
      const htmlContent = this.getZipEntry(zipEntries, fullPath);
      if (htmlContent) {
        chIndex++;
        const markdown = this.htmlToMarkdown(htmlContent);
        const title = this.extractHtmlTitle(htmlContent) || '第' + chIndex + '章';
        chapters.push({
          title: title,
          anchor: 'ch_' + chIndex,
          level: 1
        });
        contentParts.push('# ' + title + '\n\n' + markdown);
      }
    }

    const title = opfInfo.title || this.extractTitle(contentParts.join('\n'), originalFileName);
    const fullContent = contentParts.join('\n\n---\n\n');
    const characterCount = fullContent.length;
    const plainContent = fullContent.replace(/[#*`>\-\[\]()!]/g, '');

    // Extract cover image
    let coverImage: string | undefined;
    if (opfInfo.coverId) {
      const coverHref = opfInfo.manifest[opfInfo.coverId];
      if (coverHref) {
        const coverPath = baseDir + coverHref;
        coverImage = await this.extractCoverAsBase64(zipEntries, coverPath);
      }
    }

    const importMeta: ImportMeta = {
      originalFileName: originalFileName,
      fileFormat: 'epub',
      chapterCount: chapters.length,
      chapters: chapters,
      characterCount: characterCount,
      coverImage: coverImage
    };

    const tags: string[] = ['导入文档'];
    if (opfInfo.author) {
      tags.push(opfInfo.author);
    }

    const now = Date.now();
    const note: Note = {
      id: 'note_' + now + '_' + Math.random().toString(36).substring(2, 8),
      type: 'import',
      title: title,
      content: fullContent,
      contentPlain: plainContent.substring(0, 300),
      tags: tags,
      isFavorite: false,
      importMeta: importMeta,
      readProgress: 0,
      createdAt: now,
      updatedAt: now,
      deletedFlag: false
    };

    this.emitProgress('done', 100, '导入完成');
    return { note, meta: importMeta };
  }

  // ----- ZIP handling -----

  /**
   * Extract EPUB (ZIP) to a temp directory and read all entries into a Map.
   * Uses @ohos.zlib.decompressFile for extraction.
   * Temp directory is cleaned up after all files are read into memory.
   */
  private async parseZip(epubPath: string): Promise<Map<string, ArrayBuffer>> {
    // Dynamically load zlib to avoid crash on devices without @ohos.zlib
    let zlibMod: ZlibModule | null = null;
    try {
      zlibMod = await import('@ohos.zlib') as ZlibModule;
    } catch (_) {
      throw new Error('EPUB 解压失败：@ohos.zlib 模块不可用');
    }
    const zlib = zlibMod.default ?? zlibMod;
    if (!zlib || !zlib.decompressFile) {
      throw new Error('EPUB 解压失败：decompressFile 方法不可用');
    }

    // Create a unique temp directory for this extraction
    const timestamp: number = Date.now();
    const randomSuffix: string = Math.random().toString(36).substring(2, 8);
    const extractDir: string = `${this.cacheDir}/epub_${timestamp}_${randomSuffix}`;

    try {
      // Ensure cache dir exists
      try {
        fs.mkdirSync(this.cacheDir);
      } catch (_) {
        // Directory already exists
      }

      // Create extraction directory
      fs.mkdirSync(extractDir);

      // Decompress EPUB (ZIP) to temp directory
      await zlib.decompressFile(epubPath, extractDir);

      // Walk the directory and read all files into memory
      const entries: Map<string, ArrayBuffer> = new Map();
      this.walkDirectory(extractDir, extractDir, entries);

      // Clean up temp files immediately (content is in memory now)
      this.cleanupExtractDir(extractDir);

      return entries;
    } catch (err) {
      // Clean up on failure
      this.cleanupExtractDir(extractDir);
      throw new Error(err instanceof Error ? err.message : String(err));
    }
  }

  /**
   * Recursively walk a directory and read all files into the entries map.
   * Keys are relative paths (e.g. "META-INF/container.xml").
   */
  private walkDirectory(baseDir: string, currentDir: string, entries: Map<string, ArrayBuffer>): void {
    try {
      const files: string[] = fs.listFileSync(currentDir);
      for (const fileName of files) {
        const fullPath: string = `${currentDir}/${fileName}`;
        try {
          const stat = fs.statSync(fullPath);
          if (stat.isDirectory()) {
            this.walkDirectory(baseDir, fullPath, entries);
          } else {
            const relativePath: string = fullPath.substring(baseDir.length + 1).replace(/\\/g, '/');
            const file = fs.openSync(fullPath, fs.OpenMode.READ_ONLY);
            const buf = new ArrayBuffer(stat.size);
            if (stat.size > 0) {
              fs.readSync(file.fd, buf, { offset: 0, length: stat.size });
            }
            fs.closeSync(file);
            entries.set(relativePath, buf);
          }
        } catch (_) {
          // Skip unreadable files
        }
      }
    } catch (_) {
      // Skip unreadable directories
    }
  }

  /**
   * Look up a ZIP entry and return its content as a UTF-8 string.
   */
  private getZipEntry(entries: Map<string, ArrayBuffer>, path: string): string | null {
    const normalizedPath: string = path.replace(/\\/g, '/');
    const buf: ArrayBuffer | undefined = entries.get(normalizedPath);
    if (!buf) {
      // Try alternate path formats
      if (normalizedPath.startsWith('/')) {
        return this.getZipEntry(entries, normalizedPath.substring(1));
      }
      return null;
    }
    try {
      // Convert ArrayBuffer to string using TextDecoder
      const uint8: Uint8Array = new Uint8Array(buf);
      const textDecoder: util.TextDecoder = new util.TextDecoder('utf-8', { ignoreBOM: false });
      return textDecoder.decode(uint8, { stream: false });
    } catch (_) {
      return null;
    }
  }

  /**
   * Clean up the extraction directory.
   */
  private cleanupExtractDir(dirPath: string): void {
    try {
      this.removeDirectory(dirPath);
    } catch (_) {
      // Ignore cleanup errors
    }
  }

  /**
   * Recursively remove a directory and all its contents.
   */
  private removeDirectory(dirPath: string): void {
    try {
      const files: string[] = fs.listFileSync(dirPath);
      for (const fileName of files) {
        const fullPath: string = `${dirPath}/${fileName}`;
        try {
          const stat = fs.statSync(fullPath);
          if (stat.isDirectory()) {
            this.removeDirectory(fullPath);
          } else {
            fs.unlinkSync(fullPath);
          }
        } catch (_) {
          // Skip cleanup errors for individual files
        }
      }
      fs.rmdirSync(dirPath);
    } catch (_) {
      // Skip if dir doesn't exist
    }
  }

  // ----- EPUB XML parsing -----

  private extractOpfPath(containerXml: string): string | null {
    const match = containerXml.match(/full-path\s*=\s*"([^"]+)"/i);
    if (match && match[1]) {
      return match[1];
    }
    const altMatch = containerXml.match(/full-path='([^']+)'/i);
    return altMatch ? altMatch[1] : null;
  }

  private parseOpf(_opfContent: string): OpfContent {
    // Basic OPF parsing with regex
    const titleMatch = _opfContent.match(/<dc:title[^>]*>([^<]*)<\/dc:title>/i);
    const authorMatch = _opfContent.match(/<dc:creator[^>]*>([^<]*)<\/dc:creator>/i);

    const manifest: Record<string, string> = {};
    const manifestRegex = /<item[^>]*>/gi;
    let itemMatch: RegExpExecArray | null;
    while ((itemMatch = manifestRegex.exec(_opfContent)) !== null) {
      const idMatch = itemMatch[0].match(/id\s*=\s*"([^"]+)"/i);
      const hrefMatch = itemMatch[0].match(/href\s*=\s*"([^"]+)"/i);
      const mediaMatch = itemMatch[0].match(/media-type\s*=\s*"([^"]+)"/i);
      if (idMatch && hrefMatch && mediaMatch) {
        manifest[idMatch[1]] = hrefMatch[1];
      }
    }

    // Get spine order
    const spine: string[] = [];
    const spineRegex = /<itemref[^>]*>/gi;
    let spineMatch: RegExpExecArray | null;
    while ((spineMatch = spineRegex.exec(_opfContent)) !== null) {
      const idrefMatch = spineMatch[0].match(/idref\s*=\s*"([^"]+)"/i);
      if (idrefMatch && manifest[idrefMatch[1]]) {
        spine.push(manifest[idrefMatch[1]]);
      }
    }

    // Find cover
    let coverId = '';
    const coverMatch = _opfContent.match(/<meta[^>]*name\s*=\s*"cover"[^>]*content\s*=\s*"([^"]+)"/i);
    if (coverMatch) {
      coverId = coverMatch[1];
    }

    const result: OpfContent = {
      title: titleMatch ? titleMatch[1] : '',
      author: authorMatch ? authorMatch[1] : '',
      spine: spine,
      manifest: manifest,
      coverId: coverId
    };
    return result;
  }

  private extractHtmlTitle(html: string): string {
    const match = html.match(/<title[^>]*>([^<]*)<\/title>/i);
    return match ? match[1].trim() : '';
  }

  // ----- HTML to Markdown -----

  private htmlToMarkdown(html: string): string {
    let md = html;

    // Remove scripts and styles
    md = md.replace(/<script[^>]*>[\s\S]*?<\/script>/gi, '');
    md = md.replace(/<style[^>]*>[\s\S]*?<\/style>/gi, '');

    // Headings
    md = md.replace(/<h1[^>]*>([\s\S]*?)<\/h1>/gi, '# $1\n\n');
    md = md.replace(/<h2[^>]*>([\s\S]*?)<\/h2>/gi, '## $1\n\n');
    md = md.replace(/<h3[^>]*>([\s\S]*?)<\/h3>/gi, '### $1\n\n');
    md = md.replace(/<h4[^>]*>([\s\S]*?)<\/h4>/gi, '#### $1\n\n');

    // Paragraphs
    md = md.replace(/<p[^>]*>([\s\S]*?)<\/p>/gi, '$1\n\n');

    // Bold / Italic
    md = md.replace(/<strong[^>]*>([\s\S]*?)<\/strong>/gi, '**$1**');
    md = md.replace(/<b[^>]*>([\s\S]*?)<\/b>/gi, '**$1**');
    md = md.replace(/<em[^>]*>([\s\S]*?)<\/em>/gi, '*$1*');
    md = md.replace(/<i[^>]*>([\s\S]*?)<\/i>/gi, '*$1*');

    // Lists
    md = md.replace(/<li[^>]*>([\s\S]*?)<\/li>/gi, '- $1\n');
    md = md.replace(/<ul[^>]*>([\s\S]*?)<\/ul>/gi, '$1\n');
    md = md.replace(/<ol[^>]*>([\s\S]*?)<\/ol>/gi, '$1\n');

    // Blockquote
    md = md.replace(/<blockquote[^>]*>([\s\S]*?)<\/blockquote>/gi, '> $1\n\n');

    // Links
    md = md.replace(/<a[^>]*href\s*=\s*"([^"]*)"[^>]*>([\s\S]*?)<\/a>/gi, '[$2]($1)');

    // Images
    md = md.replace(/<img[^>]*src\s*=\s*"([^"]*)"[^>]*>/gi, '![Image]($1)');

    // Line breaks
    md = md.replace(/<br\s*\/?>/gi, '\n');

    // Horizontal rules
    md = md.replace(/<hr\s*\/?>/gi, '\n---\n');

    // Remove remaining tags
    md = md.replace(/<[^>]+>/g, '');

    // Decode HTML entities
    md = md.replace(/&amp;/g, '&');
    md = md.replace(/&lt;/g, '<');
    md = md.replace(/&gt;/g, '>');
    md = md.replace(/&quot;/g, '"');
    md = md.replace(/&#39;/g, "'");
    md = md.replace(/&nbsp;/g, ' ');

    // Clean up excessive blank lines
    md = md.replace(/\n{4,}/g, '\n\n\n');

    return md.trim();
  }

  private async extractCoverAsBase64(entries: Map<string, ArrayBuffer>, path: string): Promise<string | undefined> {
    const normalizedPath: string = path.replace(/\\/g, '/');
    const buf: ArrayBuffer | undefined = entries.get(normalizedPath);
    if (!buf) {
      // Try with leading slash removed
      if (normalizedPath.startsWith('/')) {
        return this.extractCoverAsBase64(entries, normalizedPath.substring(1));
      }
      return undefined;
    }
    try {
      const uint8: Uint8Array = new Uint8Array(buf);
      // Detect image type from first bytes
      let mime: string = 'image/png';
      if (uint8[0] === 0xFF && uint8[1] === 0xD8) {
        mime = 'image/jpeg';
      } else if (uint8[0] === 0x89 && uint8[1] === 0x50 && uint8[2] === 0x4E && uint8[3] === 0x47) {
        mime = 'image/png';
      } else if (uint8[0] === 0x47 && uint8[1] === 0x49 && uint8[2] === 0x46) {
        mime = 'image/gif';
      } else if (uint8[0] === 0x52 && uint8[1] === 0x49 && uint8[2] === 0x46 && uint8[3] === 0x46) {
        mime = 'image/webp';
      }
      // Convert ArrayBuffer to base64
      let binary: string = '';
      for (let i = 0; i < uint8.length; i++) {
        binary += String.fromCharCode(uint8[i]);
      }
      const base64: string = base64Encode(binary);
      return `data:${mime};base64,${base64}`;
    } catch (_) {
      return undefined;
    }
  }

  // ----- Helpers -----

  async getFileInfo(uri: string): Promise<FileInfo> {
    const stat = fs.statSync(uri);
    const name = uri.split('/').pop() || uri.split('\\').pop() || 'unknown';
    const ext = name.split('.').pop()?.toLowerCase() || '';
    const type = ext === 'epub' ? 'epub' : 'txt';
    const info: FileInfo = { name: name, size: stat.size, type: type };
    return info;
  }
}
