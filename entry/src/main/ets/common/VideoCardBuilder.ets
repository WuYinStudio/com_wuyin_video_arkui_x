/** QQ 富文本卡片（ark）构建：视频分享卡。 */

/** 视频分享卡参数。 */
export class VideoShareArgs {
  vodId: string = '';
  episodeIndex: number = 1;
  /** 选集串（标题$地址#标题$地址），会做 URL 编码后放进 scheme。 */
  wzlj: string = '';
  title: string = '';
  episodeTitle: string = '';
  cover: string = '';
  durationText: string = '';
}

const ICON: string = 'https://hhmage.com/cover/896b690b9566f53a875e03a3a324c091.jpg';

/** 生成可直接发送到 QQ/微信群的 XML 卡片文本。 */
export function buildVideoCard(args: VideoShareArgs): string {
  const title: string = args.title.length > 0 ? args.title : '无音影视';
  const episode: string = args.episodeTitle.length > 0 ? args.episodeTitle : ('第' + String(args.episodeIndex) + '集');
  const scheme: string = 'wuyinvideo://play?vodId=' + encodeURIComponent(args.vodId) +
    '&episodeIndex=' + String(args.episodeIndex) +
    (args.wzlj.length > 0 ? '&wzlj=' + encodeURIComponent(args.wzlj) : '') +
    '&title=' + encodeURIComponent(title) +
    '&cover=' + encodeURIComponent(args.cover);
  const cover: string = args.cover.length > 0 ? args.cover : ICON;
  const duration: string = args.durationText.length > 0 ? args.durationText : '';
  let xml: string = '<?xml version="1.0" encoding="utf-8"?>\n';
  xml += '<msg serviceID="1" templateID="1" action="web" brief="[无音影视] 视频分享" sourceMsgId="0"';
  xml += ' url="' + escapeAttr(scheme) + '" flag="0" adverSign="0" multiMsgFlag="0">\n';
  xml += '<item layout="2">\n' + escapeText(title + ' · ' + episode) + '\n';
  xml += '<pic>' + escapeText(cover) + '</pic>\n';
  xml += '<summary>' + escapeText(title + ' - ' + episode) + '</summary>\n';
  xml += '<hr/>\n';
  xml += '<desc>' + (duration.length > 0 ? '时长：' + escapeText(duration) + '<br/>' : '') +
    '点击唤起无音影视直接播放</desc>\n';
  xml += '</item>\n';
  xml += '<source name="无音影视" icon="' + escapeText(cover) + '"/>\n';
  xml += '</msg>';
  return xml;
}

function escapeAttr(value: string): string {
  return (value || '').replace(/&/g, '&amp;').replace(/"/g, '&quot;')
    .replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function escapeText(value: string): string {
  return (value || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
