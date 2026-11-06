import { common, bundleManager } from '@kit.AbilityKit';
import { router, window } from '@kit.ArkUI';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { Logger } from '../common/Logger';
import { Ui } from '../common/Ui';

/** 更新日志中的一个分组（例如「播放器页面布局」）。 */
class UpdateLogSection {
  title: string = '';
  items: string[] = [];

  constructor(title: string, items: string[]) {
    this.title = title;
    this.items = items;
  }
}

/** 一个版本的更新记录。 */
class UpdateLogEntry {
  version: string = '';
  date: string = '';
  title: string = '';
  timeRange: string = '';
  sections: UpdateLogSection[] = [];

  constructor(version: string, date: string, title: string, timeRange: string,
    sections: UpdateLogSection[]) {
    this.version = version;
    this.date = date;
    this.title = title;
    this.timeRange = timeRange;
    this.sections = sections;
  }
}

@Entry
@Component
struct UpdateLogPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  @StorageLink('darkTheme') @Watch('onDarkThemeChanged') private dark: boolean = true;
  @StorageLink('immersiveTopInset') private topInset: number = 24;
  @StorageLink('immersiveConfig') private immersion: PlayerImmersiveConfig = AppState.immersiveConfig;
  @State private viewportWidth: number = 360;
  @State private appVersion: string = '5.1.4';
  private scroller: Scroller = new Scroller();

  /** 与工程根目录 CHANGELOG_APP.md 保持一致，按版本倒序展示。 */
  private readonly logs: UpdateLogEntry[] = [
    new UpdateLogEntry('5.1.4', '2026-11-06', '多端侧栏 · 主题壁纸 · 富文本 XML · 播放器快捷键',
      '2026-11-05 21:00 ~ 2026-11-06 03:50', [
        new UpdateLogSection('播放器控制栏', [
          '底部「弹幕」改为「选集」，点击展开/收起选集菜单',
          '顶部移除选集、画面比例、播放倍速与截图图标',
          '播放设置齿轮移动到收藏图标右侧',
          '画面比例、播放倍速移入播放设置快捷操作区，使用鸿蒙原生图标'
        ]),
        new UpdateLogSection('播放手势与预览', [
          '长按 3 倍速仅视频右半边触发，顶部控制栏不再触发',
          '快进帧预览画面改用圆角小窗',
          '画面预览信息弹窗移到顶部控制栏下方并贴紧'
        ]),
        new UpdateLogSection('进度与 HDR', [
          '进度滑块恢复 22vp 项目图标，使用主题色 1.5vp 描边',
          '「高能进度条」开启时进度与描边使用金色 #FFB74D',
          'HDR 扫光改为圆形跟随徽标尺寸，亮带采用圆角',
          'HDR 高光改为圆形裁切的主题色左上柔光 + 底部反光'
        ]),
        new UpdateLogSection('线路选择', [
          '顶部线路图标长按 0.25 秒打开线路选择页',
          '打开时并发检测全部线路：先 HEAD，失败回退 Range GET',
          '可用线路绿色信号、不可用灰色信号，并标记当前线路',
          '支持重新检测、点击切换线路',
          '新增线路图标气泡说明，支持「不再提示」持久化'
        ]),
        new UpdateLogSection('后台与实况窗', [
          '暂停切后台时实况窗显示当前总缓存进度，回到播放器自动关闭',
          '播放器切后台立即保存当前影视、集数与进度到观看历史'
        ]),
        new UpdateLogSection('页面与社区', [
          '消息页、论坛页新增未登录遮罩与去登录入口',
          '聊天室未登录发送文本/卡片时跳转登录页',
          '修复论坛评论「发布评论返回格式异常」：兼容空响应、纯文本与 HTML 包裹 JSON',
          '首页观影记录为空时整块隐藏'
        ]),
        new UpdateLogSection('下载与搜索源', [
          '下载管理页面每 500ms 刷新进度、状态与按钮文字',
          '自定义规则启用/停用即时更新按钮文字，失败自动回滚',
          '修复规则重命名丢失启用状态、类型与扩展规则的问题'
        ]),
        new UpdateLogSection('多端侧栏与账号', [
          '平板 / PC / 智慧屏新增可折叠左侧 Dock，手机继续使用底部 Dock',
          '侧栏展开 120/136/144vp，折叠 64/72/76vp，切换带 220ms 动画',
          '侧栏固定显示首页、分类、直播、消息、论坛、管理、设置、我的',
          'Tab 竖向排列，图标与文字水平居中，折叠仅显示图标',
          '侧栏新增头像、昵称、公告、快捷键、深浅色、自定义主题与在线人数',
          '头像展开 68vp、折叠 42vp；已登录显示头像，未登录显示账号图标',
          '昵称使用主题渐变；头像与隐藏菜单之间增加分割线',
          '隐藏菜单改为图标 + 文案胶囊，折叠 / 展开位置固定'
        ]),
        new UpdateLogSection('主题与壁纸', [
          '默认主题模式改为浅色，浅色背景统一为低饱和浅米白 #FBFAF7',
          '深色模式默认纯黑，不再叠加默认背景图与极光流光',
          '主题壁纸恢复切换：选择后全局使用对应深浅渐变',
          '新增默认主题「浅金」#CFB066，图标与强调色跟随主题',
          '修复设置页深色 / 浅色单选失效',
          '修复渐变壁纸需要切换深浅色才全局生效的问题',
          'Dock 统一使用首页同款系统沉浸材质、底色与背景模糊'
        ]),
        new UpdateLogSection('分类与影视列表', [
          '侧栏筛选面板改为直角、内容居中、标题靠左，宽度按形式行计算',
          '形式单行显示「电视剧、电影、动漫、综艺」，内边距 1vp',
          '分类列表内边距 3vp、背景透明、卡片间距 10vp、每行最多 3 列',
          '分类卡片复用 FilmTile，显示真实封面、跑马灯与主题 hover 光晕',
          '类型跟随类型筛选，地区未知回退当前地区，不再显示未知',
          '预加载骨架改为满卡扫光模板，加载完成无高度跳动'
        ]),
        new UpdateLogSection('公告与富文本', [
          '侧栏新增公告入口与全屏公告弹窗，打开时淡入、缩放、上浮',
          '公告每天自动提示一次，手动查看也记录当天日期',
          '公告富文本改为纯 ArkTS 渲染，不依赖 RichText / WebView',
          '支持段落、标题、加粗、列表、分割线、图片、链接与 HTML 实体',
          '链接支持浏览器、百度搜索、QQ 群与微信群跳转',
          '公告内嵌 XML 语音卡片可直接播放、暂停与拖动进度',
          '论坛 / 消息页未登录改为全屏登录遮罩'
        ]),
        new UpdateLogSection('聊天 XML 与平台链接', [
          '聊天室支持 QQ 风格 msg 与通用 card 卡片',
          '支持音频、视频、文件、链接、图片、红包、名片、位置等类型',
          '新增微信群、抖音、快手、小红书、GitHub 链接识别与平台图标',
          '链接卡片点击拉起浏览器或对应 App，普通文本走百度搜索',
          'QQ 群 scheme 优先拉起 QQ，未安装回退 QQ 群官网',
          '在线人数接入 online_see.php，每分钟刷新一次'
        ]),
        new UpdateLogSection('文档与构建', [
          '新增 docs/RICH_TEXT_AND_XML_EXAMPLES.md',
          '新增 docs/ANNOUNCEMENT_SAMPLE.md',
          '版本号 5.1.4 / versionCode 5010004，assembleHap 构建通过'
        ])
      ]),
    new UpdateLogEntry('5.1.3', '2026-11-04', '播放器 HDR · 长按倍速 · 小窗预览',
      '2026-11-04 22:30 ~ 23:45', [
        new UpdateLogSection('播放器 HDR', [
          'HDR 改为硬件渲染：preferredHdr 选流 + XComponent hdrBrightness 控制 surface 亮度',
          'HDR 开关光效：主题色极光、旋转光带、放射光束、轨道粒子、扫描线、色散文字',
          '关闭 HDR 也有收拢动画，颜色元素跟随主题'
        ]),
        new UpdateLogSection('播放交互', [
          '长按 3 倍速：视频画面与控制栏空白区域均可触发，松手恢复原倍速',
          '拖动进度条实时帧预览：视频缩为 44% 小窗居中，松手恢复全屏',
          '进度条缓存段显示已缓存/磁盘缓存，已缓存区间可直接秒开'
        ]),
        new UpdateLogSection('播放设置', [
          '新增分辨率偏好：自动 / 1080P / 720P / 480P',
          '新增 HDR 硬件渲染开关，按当前位置重新 prepare',
          '后台播放动态申请后台运行与通知权限'
        ]),
        new UpdateLogSection('缓存与网络', [
          'HLS 分片磁盘缓存：暂停继续预取，已缓存分片本地回放',
          '广告拦截：m3u8 播放列表过滤，分片直连/本地代理回退'
        ]),
        new UpdateLogSection('页面与主题', [
          '壁纸背景支持本地视频/动图/图片，并适配首页',
          '播放器页面去除全部线条描边，控件改为无边框风格',
          '新增更新日志页面：状态栏安全区、竖向渐变透明 + 高斯模糊标题栏'
        ])
      ]),
    new UpdateLogEntry('5.0.0', '2026-10-30', '播放器重构 · 沉浸式 Dock · 扫一扫上线',
      '2026-10-30 00:05 ~ 02:57', [
        new UpdateLogSection('播放器页面布局', [
          '竖屏父容器高度改为「屏幕高度 × 2/5（5:2）」，全屏占满',
          '竖屏顶部控制栏置于视频上方、底部控制栏置于视频下方；全屏恢复覆盖式',
          '竖屏不再留左右黑边：宽度强制撑满，高度按比例，放不下时用 FIT_CROP 裁切',
          '竖屏父容器顶部外边距 = 系统状态栏高度 × 2；全屏恢复贴顶',
          '播放器父容器背景恒为纯黑；页面背景深色纯黑、浅色纯白',
          '播放页全局隐藏状态栏，离开页面自动恢复',
          '播放页始终采用深色配色（不受全局深浅设置影响）'
        ]),
        new UpdateLogSection('播放器顶部控制栏', [
          '新增设备电量图标 + 百分比（30 秒刷新，充电变色）',
          '新增当前时间（20 秒刷新）',
          '新增画面比例入口：原画 / 铺满 / 16:9 / 4:3 / 21:9',
          '竖屏仅显示：返回 · 电量 · 片名/集数 · 时间（其余图标全屏显示）',
          '竖屏时间位于「片名」与「电量」之间；电量固定最右'
        ]),
        new UpdateLogSection('锁屏', [
          '新增锁定按钮：垂直居中靠左、圆形父级、内部图标居中',
          '锁定时全屏拦截手势与控件点击，仅锁图标可点',
          '锁定后点屏幕可切换锁图标显隐（3 秒自动隐藏），带淡入淡出',
          '竖屏不显示锁定按钮；全屏锁图标左边距 = 状态栏高度 × 2'
        ]),
        new UpdateLogSection('播放能力', [
          '加载提示改为「正在加载资源中…」并带省略号动画',
          '新增 5400102（操作不允许）自动重试一次',
          '新增 5400103（IO 错误）自动切换线路重试一次'
        ]),
        new UpdateLogSection('进度条', [
          '拖动圆点替换为项目图标滑块（跟随进度移动、带主题描边、深浅色自适应）'
        ]),
        new UpdateLogSection('帧数设置', [
          '软件帧率：60 / 90 / 120 / 144 / 165 / 185 Hz，默认 60Hz',
          '播放器帧率：60 / 90 / 120 / 144 / 165 / 185 Hz，默认 60Hz，独立于「跟随系统」',
          '「跟随系统」开关默认开启；超出设备上限的挡位置灰并提示「当前设备暂不支持」',
          '设备上限通过 display.supportedRefreshRates 探测并对齐挡位'
        ]),
        new UpdateLogSection('Dock 栏外观', [
          '三种样式：液态玻璃（默认）/ 实时高斯模糊 / 沉浸光感',
          '强度滑块（0~100%）；低电量自动降低强度（阈值滑条 0~100，10 档断点）',
          '接入 com.hm.appleui.hw（AppleUI 液态玻璃透镜）：Dock 本体与选中滑块均使用实时折射透镜',
          '长按拖动滑块：触发时长 0.005 秒，滑块中心跟随手指',
          '按压/拖动时物理挤压动画（等比缩放 + 呼吸脉冲）',
          '拖动时 Dock 边框向外鼓出（鼓包层）',
          '触摸光斑：三种样式均显示，颜色取自主题',
          '深色模式滑块为黑色玻璃、浅色为白色玻璃',
          '透明度跟随「沉浸外观 · Dock 栏透明度」'
        ]),
        new UpdateLogSection('扫一扫', [
          '使用鸿蒙原生 ScanKit（scanBarcode.startScanForResult）调起系统扫码',
          '支持解析三种载荷：wuyin://player?video=...、wuyinvideo://play?...、纯 JSON',
          '解析成功后显示片名/集数，点「立即播放」跳转播放器并接续进度',
          '进入页面即检查相机权限，未授权时动态申请（ohos.permission.CAMERA）',
          '拒绝授权时提供「粘贴参数解析」兜底',
          '顶部预留状态栏安全区；底部左右两个按钮：取消 / 相册'
        ]),
        new UpdateLogSection('首页', [
          '右上角两个图标改为鸿蒙原生符号：扫一扫（barcode_viewfinder）、观看历史（clock）',
          '扫一扫 → 扫一扫页面；观看历史 → 管理页「观看历史」Tab',
          '左上角品牌标记由「无」字改为项目图标',
          '「观影记录 · 查看全部」改为跳转管理页观看历史 Tab'
        ]),
        new UpdateLogSection('登录页', [
          '顶部 logo 由「无」字改为项目图标',
          '修复《用户协议》点击无反应：补注册路由 pages/UserAgreementPage、补 @Entry、修复 main_pages.json BOM',
          '修复左上角「返回」无反应：有上一级正常返回，否则切回首页'
        ]),
        new UpdateLogSection('播放器分享', [
          '分享前提示弹窗新增「分享二维码」选项',
          '二维码通过系统分享面板发出（QQ / 微信 / 抖音 / 快手 等），失败时回退复制参数'
        ])
      ]),
    new UpdateLogEntry('5.1.2', '2026-10-31', '语音与文件上传链路修复 · 安卓麦克风授权',
      '2026-10-31 21:00 ~ 22:40', [
        new UpdateLogSection('', [
          '语音发送与文件发送统一走 dbimg 直链接口（图片、视频保持原有链路不变）',
          '仅允许音频/图片/视频文件上传，其它类型明确提示',
          '安卓端聊天室语音发送新增麦克风权限动态申请（桥接 WuYinPermission）',
          'ArkUI-X 跨平台工程完成功能移植与兼容层适配（Router/Want/Share/IME/麦克风）'
        ])
      ]),
    new UpdateLogEntry('5.1.1', '2026-10-31', '播放器控制栏与安全区调整',
      '2026-10-31 22:30 ~ 23:56', [
        new UpdateLogSection('', [
          '播放器顶部控制栏新增电量、时间、画面比例图标（鸿蒙原生符号）',
          '播放器页面移除全部状态栏安全区补偿逻辑（expandSafeArea、safeInset 等）',
          '控制栏显隐改为纯透明度过渡，修复显隐时的位置偏移',
          '修复竖屏顶部栏信息重叠'
        ])
      ]),
    new UpdateLogEntry('5.1.0', '2026-10-31 及以前', '基础版本', '', [
      new UpdateLogSection('', [
        '播放器基础播放、选集、倍速、投屏入口、收藏、下载',
        '首页搜索、分类、观影记录、Dock 导航',
        '设置页：沉浸外观、导航管理、图床、语音、运行日志',
        '表情包资源扩充至 214 个（静态 + GIF）'
      ])
    ])
  ];

  private readonly pendingItems: string[] = [
    '分享二维码海报合成（居中 + 中央 logo + 主题配色 + 底部「打开无音影视扫一扫」）：未完成，当前仅生成纯二维码',
    '扫一扫「相册」按钮：已可选图，图片解码识别待接入',
    '聊天室图片消息左侧留白：待修复',
    '聊天室头像长按 @ 用户（自动聚焦输入框、支持多人连续 @）：待实现',
    '聊天室 @昵称 文字颜色跟随主题：待实现',
    'Dock 原生 libglass.so 渲染：已接入但默认关闭，AppleUI 透镜为准'
  ];

  aboutToAppear(): void {
    void this.applySystemBars();
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName.length > 0) {
        this.appVersion = info.versionName;
      }
    } catch (error) {
      Logger.warn('UPDATE_LOG', '读取应用版本失败：' + String(error));
    }
  }

  private onDarkThemeChanged(): void {
    void this.applySystemBars();
  }

  private latestVersion(): string {
    const list: UpdateLogEntry[] = this.sortedLogs();
    return list.length > 0 ? list[0].version : this.appVersion;
  }

  private latestDate(): string {
    const list: UpdateLogEntry[] = this.sortedLogs();
    return list.length > 0 ? list[0].date : '';
  }

  private compareVersion(first: string, second: string): number {
    const a: string[] = first.split('.');
    const b: string[] = second.split('.');
    const length: number = Math.max(a.length, b.length);
    for (let index = 0; index < length; index++) {
      const left: number = index < a.length ? Number(a[index]) : 0;
      const right: number = index < b.length ? Number(b[index]) : 0;
      if (Number.isFinite(left) && Number.isFinite(right) && left !== right) {
        return left - right;
      }
    }
    return 0;
  }

  private sortedLogs(): UpdateLogEntry[] {
    const list: UpdateLogEntry[] = this.logs.slice();
    list.sort((first: UpdateLogEntry, second: UpdateLogEntry): number =>
      this.compareVersion(second.version, first.version));
    return list;
  }

  /** 状态栏安全区：返回沉浸式下顶部系统栏的实际高度。 */
  private safeTop(): number {
    return Number.isFinite(this.topInset) ? Math.max(0, this.topInset) : 24;
  }

  private blurRadius(): number {
    return Math.max(18, Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur));
  }

  /** 渐变里的透明端统一用 rgba()，避免 #00RRGGBB 被画成实心色块。 */
  private rgba(color: string, alpha: number): string {
    const raw: string = color.replace('#', '');
    const rgb: string = raw.length >= 6 ? raw.substring(raw.length - 6) : raw;
    const r: number = parseInt(rgb.substring(0, 2), 16);
    const g: number = parseInt(rgb.substring(2, 4), 16);
    const b: number = parseInt(rgb.substring(4, 6), 16);
    if (!Number.isFinite(r) || !Number.isFinite(g) || !Number.isFinite(b)) {
      return 'rgba(255,255,255,' + String(alpha) + ')';
    }
    return 'rgba(' + String(r) + ',' + String(g) + ',' + String(b) + ',' + String(alpha) + ')';
  }

  private async applySystemBars(): Promise<void> {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const currentWindow: window.Window = await window.getLastWindow(context);
      await currentWindow.setWindowLayoutFullScreen(true);
      await currentWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        isStatusBarLightIcon: this.dark,
        isNavigationBarLightIcon: this.dark,
        enableStatusBarAnimation: true,
        enableNavigationBarAnimation: true
      });
    } catch (error) {
      Logger.warn('UPDATE_LOG', '设置状态栏样式失败：' + String(error));
    }
  }

  @Builder
  private headerBar() {
    Column() {
      Row({ space: '10vp' }) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.chevron_left_circle'))
            .fontSize(Ui.fs('22vp', this.fontScale))
            .fontColor([Ui.ink(this.dark)]);
        }
          .width('36vp')
          .height('36vp')
          .borderRadius('18vp')
          .backgroundColor(Ui.glassTintSoft(this.dark))
          .accessibilityText('返回')
          .onClick(() => { router.back(); });
        Column({ space: '1vp' }) {
          Text('更新日志')
            .fontSize(Ui.fs('20vp', this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.ink(this.dark))
            .maxLines(1);
          Text('版本迭代与功能记录')
            .fontSize(Ui.fs('11vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.dark))
            .maxLines(1);
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start);
        Text('v' + this.latestVersion())
          .fontSize(Ui.fs('11vp', this.fontScale))
          .fontColor(Ui.accentStrong(this.dark))
          .padding({ left: '11vp', right: '11vp', top: '6vp', bottom: '6vp' })
          .borderRadius('14vp')
          .backgroundColor(Ui.accentSoft(this.dark));
      }
        .width('100%')
        .height('56vp')
        .alignItems(VerticalAlign.Center);
    }
      .width('100%')
      .padding({ top: this.safeTop(), left: '16vp', right: '16vp', bottom: '10vp' })
      // 竖向渐变透明 + 高斯模糊：顶部实、向下逐渐透出页面内容。
      .linearGradient({
        angle: 180,
        colors: [
          [this.rgba(Ui.pageBg(this.dark), 0.96), 0.0],
          [this.rgba(Ui.pageBg(this.dark), 0.72), 0.62],
          [this.rgba(Ui.pageBg(this.dark), 0), 1.0]
        ]
      })
      .backdropBlur(this.blurRadius());
  }

  @Builder
  private sectionBlock(entry: UpdateLogEntry, section: UpdateLogSection, sectionIndex: number) {
    Column({ space: '6vp' }) {
      if (section.title.length > 0) {
        Text(section.title)
          .fontSize(Ui.fs('12vp', this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.accentStrong(this.dark))
          .width('100%')
          .padding({ top: sectionIndex === 0 ? '0vp' : '8vp' });
      }
      ForEach(section.items, (item: string) => {
        Row({ space: '8vp' }) {
          Circle()
            .width('5vp')
            .height('5vp')
            .fill(Ui.accent(this.dark))
            .margin({ top: '7vp' });
          Text(item)
            .fontSize(Ui.fs('12.5vp', this.fontScale))
            .lineHeight(Ui.fs('19vp', this.fontScale))
            .fontColor(Ui.inkSoft(this.dark))
            .layoutWeight(1);
        }
          .width('100%')
          .alignItems(VerticalAlign.Top);
      }, (item: string, index: number): string =>
        entry.version + '-' + String(sectionIndex) + '-' + String(index));
    }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
  }

  @Builder
  private versionCard(entry: UpdateLogEntry) {
    Column({ space: '10vp' }) {
      Row({ space: '8vp' }) {
        Text('v' + entry.version)
          .fontSize(Ui.fs('11.5vp', this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Ui.accentStrong(this.dark))
          .padding({ left: '9vp', right: '9vp', top: '4vp', bottom: '4vp' })
          .borderRadius('11vp')
          .backgroundColor(Ui.accentSoft(this.dark));
        Text(entry.date)
          .fontSize(Ui.fs('10.5vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.dark));
        Blank();
      }
        .width('100%')
        .alignItems(VerticalAlign.Center);
      Text(entry.title)
        .fontSize(Ui.fs('14.5vp', this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Ui.ink(this.dark))
        .width('100%');
      if (entry.timeRange.length > 0) {
        Text(entry.timeRange)
          .fontSize(Ui.fs('10vp', this.fontScale))
          .fontColor(Ui.inkFaint(this.dark))
          .width('100%');
      }
      ForEach(entry.sections, (section: UpdateLogSection, sectionIndex: number) => {
        this.sectionBlock(entry, section, sectionIndex);
      }, (section: UpdateLogSection, sectionIndex: number): string =>
        entry.version + '-section-' + String(sectionIndex));
    }
      .width('100%')
      .padding(this.isTablet() ? '18vp' : '16vp')
      .borderRadius('22vp')
      .backgroundColor(Ui.card(this.dark))
      .border({ width: 1, color: Ui.cardBorder(this.dark) })
      .shadow({ radius: 16, color: Ui.shadowSoft(this.dark), offsetY: 6 });
  }

  @Builder
  private pendingCard() {
    Column({ space: '8vp' }) {
      Text('已知待处理')
        .fontSize(Ui.fs('14vp', this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Ui.ink(this.dark))
        .width('100%');
      ForEach(this.pendingItems, (item: string) => {
        Row({ space: '8vp' }) {
          Circle()
            .width('5vp')
            .height('5vp')
            .fill(Ui.inkFaint(this.dark))
            .margin({ top: '7vp' });
          Text(item)
            .fontSize(Ui.fs('12vp', this.fontScale))
            .lineHeight(Ui.fs('18vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.dark))
            .layoutWeight(1);
        }
          .width('100%')
          .alignItems(VerticalAlign.Top);
      }, (item: string, index: number): string => 'pending-' + String(index));
    }
      .width('100%')
      .padding(this.isTablet() ? '18vp' : '16vp')
      .borderRadius('22vp')
      .backgroundColor(Ui.card(this.dark))
      .border({ width: 1, color: Ui.cardBorder(this.dark) });
  }

  private isTablet(): boolean {
    return this.viewportWidth >= 600;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [
            [this.rgba(Ui.pageBg(this.dark), 1), 0.0],
            [this.rgba(Ui.pageBgAlt(this.dark), 1), 1.0]
          ]
        });
      Scroll(this.scroller) {
        Column({ space: '14vp' }) {
          Column({ space: '3vp' }) {
            Text('最新版本 v' + this.latestVersion())
              .fontSize(Ui.fs('15vp', this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Ui.ink(this.dark));
            Text('最近更新：' + this.latestDate() + ' · 当前安装 v' + this.appVersion)
              .fontSize(Ui.fs('11vp', this.fontScale))
              .fontColor(Ui.inkFaint(this.dark));
          }
            .width('100%')
            .alignItems(HorizontalAlign.Start);
          ForEach(this.sortedLogs(), (entry: UpdateLogEntry) => {
            this.versionCard(entry);
          }, (entry: UpdateLogEntry): string => entry.version);
          this.pendingCard();
          Text('更新记录按版本倒序整理')
            .fontSize(Ui.fs('10.5vp', this.fontScale))
            .fontColor(Ui.inkFaint(this.dark))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: '8vp', bottom: '24vp' });
        }
          .width('100%')
          .padding({
            left: this.isTablet() ? '24vp' : '16vp',
            right: this.isTablet() ? '24vp' : '16vp',
            top: this.safeTop() + 'vp',
            bottom: '28vp'
          })
          .margin({ top: '66vp' });
      }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring);
      this.headerBar();
    }
      .width('100%')
      .height('100%')
      .backgroundColor(Ui.pageBg(this.dark))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAreaChange((_old: Area, area: Area) => {
        const width: number = Number(area.width);
        if (Number.isFinite(width) && width > 0 && Math.abs(width - this.viewportWidth) > 0.5) {
          this.viewportWidth = width;
        }
      });
  }
}
