/** 路径转 file:// URI 的跨平台实现。 */
export namespace fileUri {
  export function getUriFromPath(path: string): string {
    if (path.startsWith('file://')) { return path; }
    const normalized: string = path.replace(/\\/g, '/');
    return normalized.startsWith('/') ? 'file://' + normalized : 'file:///' + normalized;
  }
}
