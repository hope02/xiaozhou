/**
 * Base64 encoding utility for ArkTS.
 * ArkTS does not expose btoa(), so we implement Base64 manually.
 * Properly handles UTF-8 encoding for non-ASCII characters (e.g. Chinese usernames/passwords).
 */

const BASE64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';

/**
 * Encode a string to Base64, with proper UTF-8 byte expansion.
 * This handles multi-byte characters (Chinese, Japanese, etc.).
 */
export function base64Encode(value: string): string {
  // Step 1: convert JS string -> UTF-8 byte array
  const bytes: number[] = [];
  for (let i = 0; i < value.length; i++) {
    let code = value.charCodeAt(i);
    // Handle surrogate pairs
    if (code >= 0xD800 && code <= 0xDBFF) {
      const hi = code;
      const lo = value.charCodeAt(++i);
      if (lo >= 0xDC00 && lo <= 0xDFFF) {
        code = ((hi - 0xD800) << 10) + (lo - 0xDC00) + 0x10000;
      } else {
        // malformed, skip
        bytes.push(0xEF, 0xBF, 0xBD); // U+FFFD
        continue;
      }
    }
    if (code < 0x80) {
      bytes.push(code);
    } else if (code < 0x800) {
      bytes.push(0xC0 | (code >> 6), 0x80 | (code & 0x3F));
    } else if (code < 0x10000) {
      bytes.push(
        0xE0 | (code >> 12),
        0x80 | ((code >> 6) & 0x3F),
        0x80 | (code & 0x3F)
      );
    } else {
      bytes.push(
        0xF0 | (code >> 18),
        0x80 | ((code >> 12) & 0x3F),
        0x80 | ((code >> 6) & 0x3F),
        0x80 | (code & 0x3F)
      );
    }
  }

  // Step 2: encode bytes -> Base64
  let output = '';
  let idx = 0;
  const len = bytes.length;
  while (idx < len) {
    const a = bytes[idx++];
    const b = idx < len ? bytes[idx++] : NaN;
    const c = idx < len ? bytes[idx++] : NaN;

    const b1 = a >> 2;
    const b2 = ((a & 3) << 4) | (Number.isNaN(b) ? 0 : (b >> 4));
    const b3 = Number.isNaN(b) ? 64 : (((b & 15) << 2) | (Number.isNaN(c) ? 0 : (c >> 6)));
    const b4 = Number.isNaN(c) ? 64 : (c & 63);
    output += BASE64_CHARS.charAt(b1) + BASE64_CHARS.charAt(b2) +
              BASE64_CHARS.charAt(b3) + BASE64_CHARS.charAt(b4);
  }
  return output;
}

export function makeBasicAuth(username: string, password: string): string {
  const payload = `${username}:${password}`;
  return `Basic ${base64Encode(payload)}`;
}
