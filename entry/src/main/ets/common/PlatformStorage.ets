/** 存储空间跨平台占位：返回保守可用空间。 */
export namespace storageStatistics {
  export async function getFreeSize(): Promise<number> {
    return 8 * 1024 * 1024 * 1024;
  }
}
