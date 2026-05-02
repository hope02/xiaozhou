/**
 * Base64 encoding utility for ArkTS.
 * ArkTS does not expose btoa(), so we implement Base64 manually.
 * Properly handles UTF-8 encoding for non-ASCII characters.
 */
export function base64Encode(value: string): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
  let output = '';
  let index = 0;
  while (index < value.length) {
    const a = value.charCodeAt(index++);
    const b = value.charCodeAt(index++);
    const c = value.charCodeAt(index++);

    const b1 = a >> 2;
    const b2 = ((a & 3) << 4) | (b >> 4);
    const b3 = Number.isNaN(b) ? 64 : (((b & 15) << 2) | (c >> 6));
    const b4 = Number.isNaN(c) ? 64 : (c & 63);
    output += chars.charAt(b1) + chars.charAt(b2) + chars.charAt(b3) + chars.charAt(b4);
  }
  return output;
}

export function makeBasicAuth(username: string, password: string): string {
  const payload = `${username}:${password}`;
  return `Basic ${base64Encode(payload)}`;
}
