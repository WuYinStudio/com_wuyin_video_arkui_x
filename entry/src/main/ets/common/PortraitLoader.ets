import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { AccountApi } from './AccountApi';
import { Logger } from './Logger';

/**
 * 头像加载器：走 http 把 echoportrait.php 的图片字节取回来，解码成 PixelMap 再给 Image 用。
 *
 * 之所以不用 Image("http://...") 直连：聊天室里的他人头像经常加载不出来（组件内部请求
 * 与服务端返回的 Content-Type / 跳转不匹配），而 http + ImageSource 这条链路在登录流程里已验证可用。
 * 结果按账号缓存，避免每条消息重复请求。
 */
export class PortraitLoader {
  private static readonly CACHE: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private static readonly PENDING: Map<string, boolean> = new Map<string, boolean>();

  static cached(user: string): image.PixelMap | undefined {
    return PortraitLoader.CACHE.get(user);
  }

  static hasPending(user: string): boolean {
    return PortraitLoader.PENDING.get(user) === true;
  }

  /** 异步加载某账号头像；完成后通过回调把 PixelMap 传出去。 */
  static async load(user: string, onReady: (pixel: image.PixelMap | undefined) => void): Promise<void> {
    const name: string = (user || '').trim();
    if (name.length === 0) {
      onReady(undefined);
      return;
    }
    const cachedPixel: image.PixelMap | undefined = PortraitLoader.CACHE.get(name);
    if (cachedPixel !== undefined) {
      onReady(cachedPixel);
      return;
    }
    if (PortraitLoader.hasPending(name)) {
      return;
    }
    PortraitLoader.PENDING.set(name, true);
    const url: string = AccountApi.portraitUrl(name);
    let request: http.HttpRequest | undefined = undefined;
    try {
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 8000,
        readTimeout: 12000
      });
      const bytes: ArrayBuffer = response.result as ArrayBuffer;
      if (bytes === undefined || bytes.byteLength === 0) {
        onReady(undefined);
        return;
      }
      const source: image.ImageSource = image.createImageSource(bytes);
      const pixel: image.PixelMap = await source.createPixelMap();
      await source.release();
      PortraitLoader.CACHE.set(name, pixel);
      onReady(pixel);
    } catch (error) {
      Logger.warn('PORTRAIT', '加载头像失败：' + name + '，' + String(error));
      onReady(undefined);
    } finally {
      PortraitLoader.PENDING.delete(name);
      if (request !== undefined) {
        request.destroy();
      }
    }
  }
}
