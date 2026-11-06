/**
 * 外链平台识别：微信、抖音、快手、小红书、GitHub。
 * 图标使用 resources/base/media 下的原生 SVG/ICO 资源。
 */
export class PlatformLinks {
  static detect(url: string): string {
    const value: string = (url || '').trim().toLowerCase();
    if (value.length === 0) { return ''; }
    if (value.indexOf('weixin.qq.com') >= 0 || value.indexOf('wechat.com') >= 0 ||
      value.startsWith('weixin://')) { return 'wechat'; }
    if (value.indexOf('douyin.com') >= 0 || value.indexOf('iesdouyin.com') >= 0 ||
      value.indexOf('tiktok.com') >= 0) { return 'douyin'; }
    if (value.indexOf('kuaishou.com') >= 0 || value.indexOf('gifshow.com') >= 0) { return 'kuaishou'; }
    if (value.indexOf('xiaohongshu.com') >= 0 || value.indexOf('xhslink.com') >= 0) { return 'xiaohongshu'; }
    if (value.indexOf('github.com') >= 0 || value.indexOf('github.io') >= 0) { return 'github'; }
    return '';
  }

  static label(key: string): string {
    if (key === 'wechat') { return '微信群'; }
    if (key === 'douyin') { return '抖音'; }
    if (key === 'kuaishou') { return '快手'; }
    if (key === 'xiaohongshu') { return '小红书'; }
    if (key === 'github') { return 'GitHub'; }
    return '';
  }

  static icon(key: string): Resource {
    if (key === 'wechat') { return $r('app.media.ic_wechat'); }
    if (key === 'douyin') { return $r('app.media.ic_douyin'); }
    if (key === 'kuaishou') { return $r('app.media.ic_kuaishou'); }
    if (key === 'xiaohongshu') { return $r('app.media.ic_xiaohongshu'); }
    return $r('app.media.ic_github');
  }
}
