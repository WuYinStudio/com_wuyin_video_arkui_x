import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { http } from '@kit.NetworkKit';
import { AppState, PlayerImmersiveConfig } from '../common/AppState';
import { ImmersiveService } from '../common/ImmersiveService';
import { Logger } from '../common/Logger';
import { NavigationScroll } from '../common/NavigationScroll';
import { SearchSource, SearchSources, VodItem } from '../common/SearchSources';
import { Ui, UiMotion } from '../common/Ui';
import { AuroraBackdrop, EmptyState, GlassChip, GlassIconButton, GlassSearchBar,
  SegmentedGlassTabs } from '../common/UiWidgets';
import { SearchPlayerParams } from './PlayerPage';
import { SymbolIcons } from '../common/SymbolIcons';

// 线路 Item 由 SearchSources 的 SearchSource interface 强类型约束，远端与本地 JSON 共用解析服务。
interface SourceItem extends SearchSource {}
interface VodRecord {
  vod_name?: string;
  vod_id?: string | number;
  vod_pic?: string;
  vod_class?: string;
  vod_remarks?: string;
  vod_play_url?: string;
  playUrl?: string;
  name?: string;
  id?: string | number;
  pic?: string;
  type_name?: string;
  remarks?: string;
  url?: string;
  yhm?: string;
  feng?: string;
  sfeng?: string;
  data?: string;
  tilie?: string | number;
  wzlj?: string;
  genxi?: string;
  zyuanuuu?: string;
}
interface BaofengHotWord {
  word?: string;
  template?: string;
  mid?: string;
}
interface BaofengHotWordResponse {
  retcode?: string;
  retmsg?: string;
  data?: BaofengHotWord[];
}
interface VodResponse {
  list?: VodRecord[];
  data?: VodRecord[];
  result?: VodRecord[];
  videos?: VodRecord[];
}
// 搜索展示数据保留既有 VodItem 字段，并完整保留 iApp 卡片携带的八项参数。
interface SearchResultItem extends VodItem {
  yhm: string;
  feng: string;
  sfeng: string;
  data: string;
  tilie: string;
  wzlj: string;
  genxi: string;
  zyuanuuu: string;
}

// 路由参数使用具体类传递，避免将接口类型直接赋给 router 的 Object 参数。
class SearchRouteParams implements SearchPlayerParams {
  yhm: string;
  feng: string;
  sfeng: string;
  data: string;
  tilie: string;
  wzlj: string;
  genxi: string;
  zyuanuuu: string;
  vodId: string;

  constructor(item: SearchResultItem) {
    this.yhm = item.yhm;
    this.feng = item.feng;
    this.sfeng = item.sfeng;
    this.data = item.data;
    this.tilie = item.tilie;
    this.wzlj = item.wzlj;
    this.genxi = item.genxi;
    this.zyuanuuu = item.zyuanuuu;
    this.vodId = item.vod_id;
  }
}

@Component
export struct SearchPage {
  @StorageLink('fontScale') private fontScale: number = 1;
  // 使用同一个持久化存储键，沿用全局沉浸配置的初始化与保存流程。
  @StorageLink('immersiveConfig') @Watch('onImmersiveConfigChanged') private immersion: PlayerImmersiveConfig = AppState.immersiveConfig;
  @StorageLink('darkTheme') @Watch('onImmersiveConfigChanged') private dark: boolean = true;
  @StorageLink('searchQuery') private query: string = '';
  @StorageLink('searchSources') private sources: SearchSource[] = [];
  @StorageLink('selectedSearchSourceId') private selectedId: number = -1;
  // 只读顶部安全区：搜索条改为吸顶玻璃页头后需要避开状态栏/挖孔，不改变任何业务状态。
  @StorageLink('immersiveTopInset') private topSafeInset: number = 24;
  // 宿主发布的底栏占位高度：底栏 + 底栏上方渐进模糊带 + 手势条，仅用于列表末尾避让。
  @StorageLink('navClearance') private navClearance: number = 186;
  @State private viewportWidth: number = 360;
  @State private focused: boolean = false;
  @State private drawerOpen: boolean = false;
  @State private refreshing: boolean = false;
  @State private sourcesLoading: boolean = false;
  @State private items: SearchResultItem[] = [];
  @State private busy: boolean = false;
  @State private pressedId: string = '';
  @State private message: string = '';
  @State private records: string[] = [];
  @State private hotWords: string[] = ['高分电影', '热播电视剧', '新番动漫', '热门综艺'];
  @State private remoteHotWords: boolean = false;
  @State private hotWordsLoading: boolean = false;
  @State private selectedCategory: string = '电视剧';
  private readonly categories: string[] = ['电影', '电视剧', '动漫', '综艺'];
  @State private failedIcons: number[] = [];
  @State private failedCovers: string[] = [];
  // 内容遮罩会同时保留背景页面，两层使用独立控制器，避免一个 Scroller 绑定多个组件。
  private readonly contentScroller: Scroller = new Scroller();
  private readonly resultScroller: Scroller = new Scroller();
  private readonly coverContentScroller: Scroller = new Scroller();
  private readonly coverResultScroller: Scroller = new Scroller();
  private readonly sourceScroller: Scroller = new Scroller();
  private debounceTimer: number = -1;
  private requestLocked: boolean = false;
  private importLocked: boolean = false;
  private requestVersion: number = 0;
  private longPressHandled: boolean = false;
  private readonly placeholder: Resource = $r('app.media.icon');

  aboutToAppear(): void {
    void this.applyFullScreen();
    void this.loadSources();
    void this.loadHotWords();
    try {
      NavigationScroll.reset('search', '进入搜索页面');
      const saved = AppStorage.get<string[]>('searchHistory');
      if (saved) { this.records = saved.slice(); }
    } catch (error) {
      Logger.error('SearchPage', '恢复搜索页面状态失败：' + String(error));
    }
  }
  private onImmersiveConfigChanged(): void {
    // 主题或毛玻璃设置改变时同步透明系统栏，始终保持全屏且不恢复安全避让。
    void this.applyFullScreen();
  }
  private async applyFullScreen(): Promise<void> {
    try {
      // 复用窗口沉浸服务及 immersiveConfig 持久化，不添加系统栏避让。
      await ImmersiveService.apply(true);
      Logger.info('SearchPage', '已同步全屏沉浸布局；底部避让为 0vp，内容可延伸至系统导航栏下层');
    } catch (error) {
      Logger.error('SearchPage', '同步全屏沉浸布局失败：' + String(error));
    }
  }
  aboutToDisappear(): void {
    if (this.debounceTimer !== -1) { clearTimeout(this.debounceTimer); this.debounceTimer = -1; }
    this.requestVersion++;
  }
  private async loadSources(): Promise<void> {
    this.sourcesLoading = true;
    try {
      await SearchSources.init();
      this.sources = SearchSources.list();
      this.ensureSelection();
      // JSON 解析：远端与本地导入的 userlist 全量解析交由 SearchSources.parse 统一处理。
      await SearchSources.refresh();
      this.sources = SearchSources.list();
      this.failedIcons = [];
      this.ensureSelection();
    } catch (error) {
      Logger.error('SearchEngineLoad', '远端拉取失败，使用本地缓存：' + String(error));
      this.sources = SearchSources.list();
      this.ensureSelection();
      this.alert('远端拉取失败，使用本地缓存');
    } finally { this.sourcesLoading = false; }
  }
  private ensureSelection(): void {
    if (!this.sources.some((source: SearchSource) => source.id === this.selectedId)) {
      this.selectedId = this.sources.length ? this.sources[0].id : -1;
    }
  }
  private alert(text: string): void {
    this.getUIContext().getPromptAction().showDialog({ title: '搜索提示', message: text, buttons: [{ text: '知道了', color: '#70B7F5' }] });
  }
  private toast(text: string): void {
    this.getUIContext().getPromptAction().showToast({ message: text });
  }
  // 搜索源导入：两页共用文件选择器、文件名校验及持久化合并服务。
  private async importSources(): Promise<void> {
    if (this.importLocked) { return; }
    this.importLocked = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (await SearchSources.importFile(context)) {
        this.sources = SearchSources.list();
        this.failedIcons = [];
        this.ensureSelection();
        this.toast('搜索源导入成功');
      }
    } catch (error) {
      Logger.error('SearchEngineLoad', '搜索页导入或 JSON 解析失败：' + String(error));
      this.toast('导入失败：' + String(error));
    } finally { this.importLocked = false; }
  }
  private async refreshSources(): Promise<void> {
    if (this.refreshing || this.sourcesLoading) { return; }
    this.refreshing = true;
    try {
      // JSON 解析：解析及持久化成功后同步完整线路列表；异常时保留已有列表。
      await SearchSources.refresh();
      this.sources = SearchSources.list();
      this.failedIcons = [];
      this.ensureSelection();
      Logger.info('SearchEngineLoad', '刷新线路成功，共 ' + this.sources.length + ' 条');
      this.toast('线路刷新成功');
    } catch (error) {
      Logger.error('SearchEngineLoad', '刷新线路或 JSON 解析失败：' + String(error));
      this.toast('刷新线路失败，已保留原有线路');
    } finally { this.refreshing = false; }
  }
  private selectSource(source: SourceItem): void {
    this.selectedId = source.id;
    this.drawerOpen = false;
    Logger.info('SearchEngineLoad', '切换资源线路：' + source.name);
    if (this.query.trim()) { this.scheduleSearch(); }
  }
  private activeSource(): SearchSource | undefined {
    return this.sources.find((source: SearchSource) => source.id === this.selectedId);
  }
  private scheduleSearch(): void {
    if (this.debounceTimer !== -1) { clearTimeout(this.debounceTimer); }
    this.debounceTimer = setTimeout(() => { this.debounceTimer = -1; void this.search(); }, 400);
  }
  private useKeyword(word: string): void { this.query = word; this.scheduleSearch(); }
  private remember(word: string): void {
    this.records = [word].concat(this.records.filter((entry: string) => entry !== word)).slice(0, 20);
    AppStorage.setOrCreate('searchHistory', this.records.slice());
  }
  private decodeXml(text: string): string {
    return text.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1').replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'");
  }
  private xmlField(xml: string, tag: string): string {
    const match = new RegExp('<' + tag + '(?:\\s[^>]*)?>([\\s\\S]*?)<\\/' + tag + '>', 'i').exec(xml);
    return match ? this.decodeXml(match[1]).trim() : '';
  }
  private parseXml(text: string): VodRecord[] {
    const entries: VodRecord[] = [];
    const matcher = /<video(?:\s[^>]*)?>([\s\S]*?)<\/video>/gi;
    let match: RegExpExecArray | null;
    while ((match = matcher.exec(text)) !== null) {
      const block = match[1];
      const record: VodRecord = { vod_name: this.xmlField(block, 'name'), vod_id: this.xmlField(block, 'id'),
          vod_pic: this.xmlField(block, 'pic'), vod_class: this.xmlField(block, 'type'),
          vod_remarks: this.xmlField(block, 'note'), vod_play_url: this.xmlField(block, 'dd'),
          yhm: this.xmlField(block, 'yhm'), feng: this.xmlField(block, 'feng'),
          sfeng: this.xmlField(block, 'sfeng'), data: this.xmlField(block, 'data'),
          tilie: this.xmlField(block, 'tilie'), wzlj: this.xmlField(block, 'wzlj'),
          genxi: this.xmlField(block, 'genxi'), zyuanuuu: this.xmlField(block, 'zyuanuuu') };
      entries.push(record);
    }
    return entries;
  }
  private parseJson(text: string): VodRecord[] {
    const parsed: VodResponse | VodRecord[] = JSON.parse(text) as VodResponse | VodRecord[];
    if (Array.isArray(parsed)) { return parsed as VodRecord[]; }
    const payload = parsed as VodResponse;
    if (payload && Array.isArray(payload.list)) { return payload.list; }
    if (payload && Array.isArray(payload.data)) { return payload.data; }
    if (payload && Array.isArray(payload.result)) { return payload.result; }
    if (payload && Array.isArray(payload.videos)) { return payload.videos; }
    throw new Error('搜索结果缺少影片列表');
  }
  // id0/id1/id2/id3/id4：保留线路 ID 分支和 XML/JSON 解析。
  private parseResults(text: string, source: SearchSource): SearchResultItem[] {
    let rows: VodRecord[];
    switch (source.id) {
      case 0: rows = text.trim().startsWith('<') ? this.parseXml(text) : this.parseJson(text); break;
      case 1: rows = text.trim().startsWith('<') ? this.parseXml(text) : this.parseJson(text); break;
      case 2: rows = text.trim().startsWith('<') ? this.parseXml(text) : this.parseJson(text); break;
      case 3: rows = text.trim().startsWith('<') ? this.parseXml(text) : this.parseJson(text); break;
      case 4: rows = text.trim().startsWith('<') ? this.parseXml(text) : this.parseJson(text); break;
      default: rows = text.trim().startsWith('<') ? this.parseXml(text) : this.parseJson(text); break;
    }
    return rows.filter((row: VodRecord) => !!(row.yhm || row.vod_name || row.name)).map((row: VodRecord): SearchResultItem => {
      const picture: string = String(row.feng || row.vod_pic || row.pic || '').trim();
      const base: string = source.urls.trim().replace(/\/$/, '');
      const coverUrl: string = picture ? (/^https?:\/\//i.test(picture) ? picture : base + '/' + picture.replace(/^\//, '')) : '';
      const name: string = String(row.yhm || row.vod_name || row.name || '');
      const summary: string = String(row.sfeng || row.vod_remarks || row.remarks || '');
      const address: string = String(row.wzlj || row.playUrl || row.vod_play_url || row.url || '').trim();
      const item: SearchResultItem = { vod_name: name, vod_id: String(row.vod_id || row.id || ''),
          vod_pic: coverUrl, vod_class: String(row.data || row.vod_class || row.type_name || ''),
          vod_remarks: summary, playUrl: address,
          yhm: name, feng: coverUrl, sfeng: summary, data: String(row.data || row.vod_class || row.type_name || ''),
          tilie: row.tilie === undefined || row.tilie === null ? '' : String(row.tilie),
          wzlj: address, genxi: String(row.genxi || row.remarks || row.vod_remarks || ''),
          zyuanuuu: String(row.zyuanuuu || source.name || '') };
      return item;
    });
  }
  private async searchSource(source: SearchSource, word: string, version: number): Promise<SearchResultItem[]> {
    const request = http.createHttp();
    try {
      const response = await request.request(source.url + encodeURIComponent(word), {
        method: http.RequestMethod.GET, connectTimeout: 8000, readTimeout: 10000
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error('搜索服务错误 ' + response.responseCode);
      }
      return version === this.requestVersion ? this.parseResults(String(response.result), source) : [];
    } catch (error) {
      Logger.warn('SearchEngineLoad', '线路「' + source.name + '」搜索失败：' + String(error));
      return [];
    } finally {
      request.destroy();
    }
  }

  /** 按片名去重：同名影片只保留一条；若首条没有播放地址而后续线路有，则用后续线路补全。 */
  private mergeByTitle(groups: SearchResultItem[][]): SearchResultItem[] {
    const titles: string[] = [];
    const merged: SearchResultItem[] = [];
    for (const group of groups) {
      for (const item of group) {
        const title: string = String(item.yhm || item.vod_name || '').trim();
        const key: string = title.toLowerCase();
        if (!key) {
          continue;
        }
        const index: number = titles.indexOf(key);
        if (index < 0) {
          titles.push(key);
          merged.push(item);
        } else if (!merged[index].playUrl && item.playUrl) {
          merged[index] = item;
        }
      }
    }
    return merged;
  }

  private async search(): Promise<void> {
    const word = this.query.trim();
    if (!word || this.sources.length === 0) {
      this.items = [];
      this.message = word ? '请先选择搜索源' : '';
      return;
    }
    if (this.requestLocked) {
      this.scheduleSearch();
      return;
    }
    this.requestLocked = true;
    this.busy = true;
    const version = ++this.requestVersion;
    try {
      // 所有线路并发请求；单条线路失败不影响其它线路。
      const jobs: Promise<SearchResultItem[]>[] = [];
      for (const source of this.sources) {
        jobs.push(this.searchSource(source, word, version));
      }
      const groups: SearchResultItem[][] = await Promise.all(jobs);
      if (version === this.requestVersion) {
        const merged: SearchResultItem[] = this.mergeByTitle(groups);
        this.failedCovers = [];
        this.items = merged;
        this.message = merged.length === 0 ? '所有线路均未找到相关影片' : '';
        this.remember(word);
        Logger.info('SearchEngineLoad', '全部线路并发搜索完成，线路=' + String(groups.length) +
          '，去重后=' + String(merged.length) + ' 条');
      }
    } catch (error) {
      Logger.error('SearchEngineLoad', '并发搜索失败：' + String(error));
      if (version === this.requestVersion) {
        this.items = [];
        this.message = '搜索失败，请检查线路或网络';
        this.alert(this.message);
      }
    } finally {
      this.requestLocked = false;
      this.busy = false;
    }
  }
  // 保持具体类型，避免 ArkTS 在路由参数处进行不支持的结构化类型匹配。
  private params(item: SearchResultItem): SearchRouteParams {
    return new SearchRouteParams(item);
  }
  private async play(item: SearchResultItem): Promise<void> {
    if (this.longPressHandled) { this.longPressHandled = false; return; }
    try {
      const video: SearchRouteParams = this.params(item);
      const playerUri: string = 'pages/PlayerPage';
      Logger.info('SearchEngineLoad', '点击影片，完整SearchVideoItem：' + JSON.stringify(item));
      Logger.info('SearchEngineLoad', '跳转参数：' + JSON.stringify(video));
      Logger.info('SearchEngineLoad', '跳转前完整wzlj分集原始字符串：' + item.wzlj);
      await router.pushUrl({ url: playerUri, params: video });
      Logger.info('SearchEngineLoad', '已跳转PlayerPage：' + video.yhm);
    } catch (error) {
      Logger.error('SearchEngineLoad', '跳转PlayerPage失败：' + String(error));
      this.toast('打开播放器失败，请稍后重试');
    }
  }
  // 长按仅进入影片详情，不要求播放源存在；后续 click 事件不再误进播放器。
  private openDetail(item: SearchResultItem): void {
    this.longPressHandled = true;
    try {
      const params: SearchRouteParams = this.params(item);
      AppStorage.setOrCreate('searchDetailParams', params);
      Logger.info('SearchEngineLoad', '长按进入影片详情：' + params.yhm);
      AppState.go('detail');
    } catch (error) {
      Logger.error('SearchEngineLoad', '跳转影片详情失败：' + String(error));
      this.toast('打开影片详情失败');
    }
  }
  private updateViewportWidth(area: Area): void {
    try {
      // Area 测量值与动态布局尺寸均为 vp，百分比仅用于撑满父容器。
      const measuredViewportWidth: number = Number(area.width);
      if (!Number.isFinite(measuredViewportWidth) || measuredViewportWidth <= 0) {
        Logger.warn('SearchPage', '页面宽度测量无效，保留原有 vp 布局尺寸');
        return;
      }
      this.viewportWidth = measuredViewportWidth;
    } catch (error) {
      Logger.error('SearchPage', '更新全屏页面尺寸失败：' + String(error));
    }
  }
  private tablet(): boolean { return this.viewportWidth >= 600; }
  private drawerSize(): number { return this.tablet() ? 320 : this.viewportWidth * 0.65; }
  // 以下取值统一走设计令牌，深浅模式与毛玻璃强度由 Ui 换算，页面不再写死色值。
  private ink(): string { return Ui.ink(this.dark); }
  private muted(): string { return Ui.inkSoft(this.dark); }
  private panel(): string { return Ui.glassTintSoft(this.dark); }
  private glass(): number { return Ui.glassBlur(this.immersion.immersiveEnable, this.immersion.immersiveBlur); }
  private iconFailed(id: number): void {
    if (!this.failedIcons.includes(id)) { this.failedIcons = this.failedIcons.concat([id]); }
    Logger.warn('SearchEngineLoad', '线路图标加载失败，使用默认图');
  }
  private coverFailed(path: string): void {
    if (!this.failedCovers.includes(path)) { this.failedCovers = this.failedCovers.concat([path]); }
    Logger.warn('SearchEngineLoad', '影片封面加载失败，使用默认图');
  }

  // 吸顶玻璃页头：左返回 + 液态玻璃搜索条；输入/提交继续走原有防抖与搜索方法。
  @Builder private searchBar() {
    Row({ space: 10 }) {
      GlassIconButton({
        iconSize: 40,
        symbol: $r('sys.symbol.chevron_left_circle'),
        accessibilityLabel: '返回首页',
        onTap: (): void => { AppState.go('home'); }
      })
      Column() {
        GlassSearchBar({
          query: this.query,
          placeholder: this.tablet() ? '搜索影片、演员、导演或剧集' : '搜索影片 / 演员 / 导演',
          showButton: true,
          onQueryChange: (text: string): void => { this.query = text; this.scheduleSearch(); },
          onSubmit: (): void => { void this.search(); },
          onFocusChange: (focused: boolean): void => { this.focused = focused; }
        })
      }
        .layoutWeight(1)
    }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({
        left: Ui.gutter(this.viewportWidth),
        right: Ui.gutter(this.viewportWidth),
        top: Math.max(0, this.topSafeInset) + 10,
        bottom: 10
      })
  }
  // 线路切换：玻璃胶囊按钮 + 当前线路胶囊，抽屉仍由原有 drawerOpen 控制。
  @Builder private sourceTabs() {
    Row({ space: 8 }) {
      Row({ space: 6 }) {
        Text('☰').fontSize(Ui.fs('14vp', this.fontScale)).fontColor(Ui.accent(this.dark))
        Text('资源线路').fontSize(Ui.fs('12.5vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor(this.ink()).maxLines(1)
      }
        .height('36vp')
        .padding({ left: '13vp', right: '14vp' })
        .borderRadius('18vp')
        .backgroundColor(Ui.glassTintSoft(this.dark))
        .backdropBlur(this.glass())
        .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
        .shadow({ radius: 8, color: Ui.shadowSoft(this.dark), offsetY: 3 })
        .accessibilityText('打开资源线路抽屉')
        .onClick(() => { this.drawerOpen = true; })
      Row({ space: 6 }) {
        Column()
          .width('6vp').height('6vp').borderRadius('3vp')
          .backgroundColor(this.sourcesLoading ? Ui.inkFaint(this.dark) : Ui.success(this.dark))
        Text(this.sources.length > 0 ? '全部线路 · ' + String(this.sources.length) + ' 条' : '请选择线路')
          .fontSize(Ui.fs('12.5vp', this.fontScale)).fontColor(this.muted()).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
        .layoutWeight(1)
        .height('36vp')
        .padding({ left: '12vp', right: '12vp' })
        .borderRadius('18vp')
        .backgroundColor(Ui.card(this.dark))
        .border({ width: 1, color: Ui.cardBorderSoft(this.dark) })
        .alignItems(VerticalAlign.Center)
    }
      .width('100%')
      .alignItems(VerticalAlign.Center)
  }
  // 资源线路抽屉：液态玻璃面板 + 大圆角 + 顶部手柄。
  @Builder private sourceDrawer() {
    Column() {
      Row() {
        Row()
          .width('40vp').height('4vp').borderRadius('2vp')
          .backgroundColor(Ui.inkFaint(this.dark))
          .opacity(0.55)
      }
        .width('100%')
        .height('18vp')
        .justifyContent(FlexAlign.Center)
      Column({ space: 12 }) {
        Row({ space: 10 }) {
          Column({ space: 2 }) {
            Text('资源线路').fontSize(Ui.fs('19vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor(this.ink()).maxLines(1)
            Text('共 ' + this.sources.length + ' 条线路 · 全部并发搜索，按片名去重')
              .fontSize(Ui.fs('11vp', this.fontScale)).fontColor(Ui.inkFaint(this.dark)).maxLines(1)
          }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          GlassIconButton({
            iconSize: 34,
            symbol: $r('sys.symbol.xmark'),
            accessibilityLabel: '关闭资源线路抽屉',
            onTap: (): void => { this.drawerOpen = false; }
          })
        }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        Row({ space: 8 }) {
          Row() {
            Text('导入线路').fontSize(Ui.fs('12.5vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor(this.ink())
          }
            .layoutWeight(1)
            .height('40vp')
            .justifyContent(FlexAlign.Center)
            .borderRadius('20vp')
            .backgroundColor(Ui.glassTintSoft(this.dark))
            .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
            .onClick(() => { void this.importSources(); })
          Row() {
            Text(this.refreshing || this.sourcesLoading ? '刷新中…' : '刷新线路')
              .fontSize(Ui.fs('12.5vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor(this.ink())
          }
            .layoutWeight(1)
            .height('40vp')
            .justifyContent(FlexAlign.Center)
            .borderRadius('20vp')
            .backgroundColor(Ui.glassTintSoft(this.dark))
            .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
            .onClick(() => { void this.refreshSources(); })
        }
          .width('100%')
        if (this.refreshing || this.sourcesLoading) {
          Row() {
            LoadingProgress().width('20vp').height('20vp').color(Ui.accent(this.dark))
          }
            .width('100%')
            .justifyContent(FlexAlign.Center)
        }
        // Scroll 纵向列表：固定顶部按钮，列表占据抽屉剩余空间；线路数量不受限制。
        Scroll(this.sourceScroller) {
          Column({ space: 8 }) {
            ForEach(this.sources, (source: SourceItem) => {
              Row({ space: 10 }) {
                Image(this.failedIcons.includes(source.id) ? this.placeholder : (source.img || this.placeholder))
                  .width('30vp').height('30vp').objectFit(ImageFit.Cover).borderRadius('9vp')
                  .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
                  .onError(() => { this.iconFailed(source.id); })
                Text(source.name)
                  .fontSize(Ui.fs('14vp', this.fontScale))
                  .fontColor(this.selectedId === source.id ? Ui.accentStrong(this.dark) : this.ink())
                  .maxLines(1)
                  .layoutWeight(1)
                if (this.selectedId === source.id) {
                  Text('✓').fontSize(Ui.fs('13vp', this.fontScale)).fontColor(Ui.accent(this.dark))
                }
              }
                .width('100%')
                .height('52vp')
                .padding({ left: '10vp', right: '10vp' })
                .borderRadius(Ui.R_SM)
                .backgroundColor(this.selectedId === source.id ? Ui.accentSoft(this.dark) : this.panel())
                .border({
                  width: 1,
                  color: this.selectedId === source.id ? Ui.glassRingAccent(this.dark) : Ui.cardBorderSoft(this.dark)
                })
                .scale({
                  x: this.pressedId === 'src-' + source.id ? 0.97 : 1,
                  y: this.pressedId === 'src-' + source.id ? 0.97 : 1
                })
                .animation({ duration: UiMotion.PRESS, curve: Curve.FastOutSlowIn })
                .onTouch((event: TouchEvent) => {
                  this.pressedId = event.type === TouchType.Down ? 'src-' + source.id : '';
                })
                .onClick(() => { this.selectSource(source); })
            }, (source: SourceItem) => source.id.toString())
          }.width('100%')
        }.scrollable(ScrollDirection.Vertical).scrollBar(BarState.Auto).layoutWeight(1).width('100%')
          .onScrollStart(() => { NavigationScroll.begin('search', 'sources', this.sourceScroller); })
          .onDidScroll((_xOffset: number, _yOffset: number, scrollState: ScrollState) => {
          NavigationScroll.report('search', 'sources', this.sourceScroller, scrollState);
        })
          .onScrollStop(() => { NavigationScroll.end('search', 'sources', this.sourceScroller); })
          .padding({ bottom: '0vp' }).margin({ bottom: '0vp' })
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: '14vp', right: '14vp', top: '2vp', bottom: '12vp' })
    }
      .width(this.drawerSize() + 'vp')
      .height('100%')
      .padding({ top: Math.max(0, this.topSafeInset) + 6 })
      .backgroundColor(Ui.glassTintStrong(this.dark))
      .backdropBlur(this.glass())
      .border({ width: 1, color: Ui.glassRing(this.dark) })
      .borderRadius({ topRight: Ui.R_LG, bottomRight: Ui.R_LG })
      .shadow({ radius: 26, color: Ui.shadow(this.dark), offsetX: 10 })
      .clip(true)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .transition(TransitionEffect.translate({ x: '-320vp', y: '0vp' }).animation({ duration: 240 }))
  }
  private async loadHotWords(): Promise<void> {
    if (this.hotWordsLoading) { return; }
    this.hotWordsLoading = true;
    const request = http.createHttp();
    try {
      const response = await request.request('http://www.baofeng.com/ps/v6/search/hotword?cl=newweb_baofeng', {
        method: http.RequestMethod.GET, connectTimeout: 8000, readTimeout: 10000,
        header: { 'Accept': 'application/json' }
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error('暴风热词接口返回 ' + response.responseCode);
      }
      const payload = JSON.parse(String(response.result)) as BaofengHotWordResponse;
      if (payload.retcode !== '200' || !Array.isArray(payload.data)) {
        throw new Error('暴风热词接口数据格式异常');
      }
      const words: string[] = payload.data
        .filter((item: BaofengHotWord) => !!(item.word && item.word.trim()))
        .map((item: BaofengHotWord) => String(item.word).trim());
      if (words.length > 0) {
        this.hotWords = words;
        this.remoteHotWords = true;
        Logger.info('SearchHotWords', '已加载暴风热词 ' + words.length + ' 条');
      }
    } catch (error) {
      this.remoteHotWords = false;
      Logger.warn('SearchHotWords', '暴风热词获取失败，继续使用本地推荐词：' + String(error));
    } finally {
      request.destroy();
      this.hotWordsLoading = false;
    }
  }
  private recommendations(): string[] {
    if (this.remoteHotWords && this.hotWords.length > 0) { return this.hotWords; }
    if (this.selectedCategory === '电影') { return ['高分电影', '悬疑电影', '科幻电影', '喜剧电影', '动作电影']; }
    if (this.selectedCategory === '动漫') { return ['热门动漫', '热血新番', '经典动漫', '国漫推荐', '治愈番']; }
    if (this.selectedCategory === '综艺') { return ['热门综艺', '真人秀', '音乐综艺', '喜剧综艺', '旅行综艺']; }
    return ['热播电视剧', '悬疑剧', '古装剧', '都市剧', '高分剧集'];
  }
  // 题材分段：复用统一的分段玻璃 Tab（选中项是滑动胶囊）。
  @Builder private categoryTabs() {
    Row() {
      SegmentedGlassTabs({
        labels: this.categories,
        active: Math.max(0, this.categories.indexOf(this.selectedCategory)),
        trackWidth: Math.max(220, Math.min(this.viewportWidth - Ui.gutter(this.viewportWidth) * 2, 560)),
        trackHeight: 44,
        compact: false,
        onSelect: (index: number): void => {
          this.selectedCategory = this.categories[index];
          if (!this.remoteHotWords) { this.hotWords = this.recommendations(); }
        }
      })
    }
      .width('100%')
  }
  @Builder private recommendationSection() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(this.remoteHotWords ? '暴风实时热词' : '热榜推荐')
          .fontSize(Ui.fs(Ui.fsTitle(this.viewportWidth), this.fontScale)).fontWeight(FontWeight.Bold).fontColor(this.ink())
          .maxLines(1)
        Row() {
          Text('HOT').fontSize(Ui.fs('10vp', this.fontScale)).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
        }
          .height('20vp')
          .padding({ left: '7vp', right: '7vp' })
          .borderRadius('10vp')
          .linearGradient({ angle: 110, colors: [[Ui.BRAND_WARM, 0], [Ui.brandTo(), 1]] })
          .shadow({ radius: 8, color: Ui.accentGlow(this.dark), offsetY: 2 })
        Blank()
        Text(this.hotWordsLoading ? '加载中…' : (this.remoteHotWords ? '暴风热词 · 点击即搜' : '本地推荐 · 点击即搜'))
          .fontSize(Ui.fs(Ui.fsCaption(this.viewportWidth), this.fontScale)).fontColor(Ui.inkFaint(this.dark))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.End).layoutWeight(1)
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      Column({ space: 8 }) {
        ForEach(this.recommendations(), (word: string, index: number) => {
          Row({ space: 10 }) {
            Text(index === 0 ? '01' : (index === 1 ? '02' : (index === 2 ? '03' : (index + 1).toString())))
              .fontSize(Ui.fs('16vp', this.fontScale)).fontWeight(FontWeight.Bold)
              .fontColor(index === 0 ? Ui.danger(this.dark) : (index === 1 ? Ui.gold(this.dark) :
              (index === 2 ? Ui.accent(this.dark) : Ui.inkFaint(this.dark))))
              .width('26vp').textAlign(TextAlign.Center)
            Column({ space: 3 }) {
              Text(word).fontSize(Ui.fs('14vp', this.fontScale)).fontWeight(FontWeight.Medium).fontColor(this.ink())
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.remoteHotWords ? '暴风全站热词' : this.selectedCategory + ' · 推荐搜索词')
                .fontSize(Ui.fs(Ui.fsCaption(this.viewportWidth), this.fontScale)).fontColor(this.muted()).maxLines(1)
            }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            Text('搜索 ›').fontSize(Ui.fs('11.5vp', this.fontScale)).fontColor(Ui.accent(this.dark)).maxLines(1)
          }
            .width('100%')
            .height('56vp')
            .padding({ left: '12vp', right: '12vp' })
            .borderRadius(Ui.R_SM)
            .backgroundColor(this.panel())
            .border({ width: 1, color: Ui.cardBorderSoft(this.dark) })
            .onClick(() => this.useKeyword(word))
        }, (word: string) => this.selectedCategory + '-' + word)
      }
        .width('100%')
      Text(this.remoteHotWords ? '数据来源：暴风影音热词接口；该接口为全站热词，不区分电影、电视剧、动漫和综艺，也不代表播放量排名。' : '当前使用本地备用推荐词；网络恢复后会尝试加载暴风影音热词。')
        .fontSize(Ui.fs('10vp', this.fontScale)).fontColor(Ui.inkFaint(this.dark)).width('100%')
    }
      .width('100%')
      .padding(Ui.S_MD)
      .borderRadius(Ui.R_LG)
      .linearGradient({
        angle: 135,
        colors: [[Ui.cardTop(this.dark), 0], [Ui.cardBottom(this.dark), 1]]
      })
      .border({ width: 1, color: Ui.cardBorder(this.dark) })
      .shadow({ radius: 16, color: Ui.shadowSoft(this.dark), offsetY: 8 })
  }
  // 快捷热搜 / 最近搜索：玻璃胶囊流式布局。
  @Builder private keywordSection(title: string, words: string[]) {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text(title).fontSize(Ui.fs(Ui.fsTitle(this.viewportWidth), this.fontScale)).fontColor(this.ink())
          .fontWeight(FontWeight.Bold).maxLines(1).layoutWeight(1)
        Text(words.length + ' 个词').fontSize(Ui.fs(Ui.fsCaption(this.viewportWidth), this.fontScale))
          .fontColor(Ui.inkFaint(this.dark)).maxLines(1)
      }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(words, (word: string) => {
          GlassChip({
            label: word,
            compact: false,
            onTap: (): void => { this.useKeyword(word); }
          })
            .margin({ right: 8, bottom: 8 })
        }, (word: string) => title + '-' + word)
      }.width('100%')
    }
      .width('100%')
  }
  // 结果海报：3:4 圆角 16，加载失败回落 app.media.icon 占位。
  @Builder private cover(item: SearchResultItem) {
    Stack({ alignContent: Alignment.BottomStart }) {
      Image(this.failedCovers.includes(item.vod_pic) ? this.placeholder : (item.vod_pic || this.placeholder))
        .width('100%').height('100%').objectFit(ImageFit.Cover)
        .onError(() => { this.coverFailed(item.vod_pic); })
      Column()
        .width('100%').height('46%')
        .linearGradient({ angle: 180, colors: [['#00000000', 0], ['#66000000', 1]] })
    }
      .width(this.tablet() ? 104 : 88)
      .height(this.tablet() ? 139 : 117)
      .borderRadius(16)
      .clip(true)
      .border({ width: 1, color: Ui.glassRingSoft(this.dark) })
      .shadow({ radius: 10, color: Ui.shadowSoft(this.dark), offsetY: 5 })
  }
  @Builder private filmCard(item: SearchResultItem) {
    Row({ space: 12 }) {
      this.cover(item)
      Column({ space: 7 }) {
        Text(item.vod_name)
          .fontSize(Ui.fs(Ui.fsTitle(this.viewportWidth), this.fontScale)).fontWeight(FontWeight.Bold).fontColor(this.ink())
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Row({ space: 6 }) {
          GlassChip({ label: item.vod_class || '未分类', compact: true })
        }
          .width('100%')
        Text(item.vod_remarks || '暂无备注')
          .fontSize(Ui.fs(Ui.fsCaption(this.viewportWidth), this.fontScale)).fontColor(this.muted())
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text('点击查看播放')
          .fontSize(Ui.fs(Ui.fsCaption(this.viewportWidth), this.fontScale)).fontColor(Ui.inkFaint(this.dark))
          .maxLines(1).width('100%')
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.play_fill')).fontSize(Ui.fs('15vp', this.fontScale)).fontColor(['#FFFFFF'])
      }
        .width('36vp').height('36vp').borderRadius('18vp')
        .linearGradient({ angle: 110, colors: [[Ui.brandFrom(), 0], [Ui.brandTo(), 1]] })
        .shadow({ radius: 10, color: Ui.accentGlow(this.dark), offsetY: 3 })
        .alignSelf(ItemAlign.Center)
    }
      .width('100%')
      .padding(Ui.S_MD)
      .backgroundColor(Ui.glassTintSoft(this.dark))
      .borderRadius(Ui.R_MD)
      .border({ width: 1, color: Ui.cardBorderSoft(this.dark) })
      .shadow({ radius: 14, color: Ui.shadowSoft(this.dark), offsetY: 6 })
      .scale({
        x: this.pressedId === item.vod_id ? 0.97 : 1,
        y: this.pressedId === item.vod_id ? 0.97 : 1
      })
      .onTouch((event: TouchEvent) => { this.pressedId = event.type === TouchType.Down ? item.vod_id : ''; })
      .onClick(() => { void this.play(item); }).gesture(LongPressGesture().onAction(() => { this.openDetail(item); }))
      .animation({ duration: UiMotion.PRESS, curve: Curve.FastOutSlowIn })
      .transition(TransitionEffect.OPACITY)
  }
  @Builder private resultList(listScroller: Scroller, scrollSource: string) {
    Column({ space: 12 }) {
      Text(this.busy ? '正在搜索…' : '搜索结果 · ' + this.items.length)
        .fontSize(Ui.fs(Ui.fsSection(this.viewportWidth), this.fontScale)).fontWeight(FontWeight.Bold).fontColor(this.ink()).width('100%')
      if (this.items.length === 0) {
        Column() {
          if (this.busy) {
            Column({ space: 10 }) {
              LoadingProgress().width('30vp').height('30vp').color(Ui.accent(this.dark))
              Text('正在搜索…').fontSize(Ui.fs('12.5vp', this.fontScale)).fontColor(this.muted()).maxLines(1)
            }
              .width('100%')
              .height('150vp')
              .justifyContent(FlexAlign.Center)
          } else {
            EmptyState({
              title: this.message || (this.query.trim() ? '没有找到相关影片' : '输入关键词开始搜索'),
              hint: this.query.trim() ? '换个关键词，或在「资源线路」中切换线路' : '支持影片名、演员和导演',
              icon: SymbolIcons.doc()
            })
          }
        }
          .width('100%')
          .borderRadius(Ui.R_LG)
          .linearGradient({
            angle: 135,
            colors: [[Ui.cardTop(this.dark), 0], [Ui.cardBottom(this.dark), 1]]
          })
          .border({ width: 1, color: Ui.cardBorder(this.dark) })
          .shadow({ radius: 16, color: Ui.shadowSoft(this.dark), offsetY: 8 })
      } else {
        Grid(listScroller) {
          ForEach(this.items, (item: SearchResultItem, index: number) => {
            GridItem() { this.filmCard(item) }
          }, (item: SearchResultItem, index: number) => item.vod_id + '-' + index)
        }.columnsTemplate(this.tablet() ? '1fr 1fr' : '1fr').columnsGap('12vp').rowsGap('12vp').width('100%')
          .onScrollStart(() => { NavigationScroll.begin('search', scrollSource, listScroller); })
          .onDidScroll((_scrollOffset: number, scrollState: ScrollState) => {
          NavigationScroll.report('search', scrollSource, listScroller, scrollState);
        })
          .onScrollStop(() => { NavigationScroll.end('search', scrollSource, listScroller); })
      }
    }.width('100%')
  }
  // 全屏内容层不读取任何系统栏安全间距；保留原有 UI 内边距，仅取消底部避让。
  @Builder private searchContent(pageScroller: Scroller, listScroller: Scroller, scrollPrefix: string) {
    Column() {
      this.searchBar()
      Scroll(pageScroller) {
        Column({ space: 12 }) {
          this.sourceTabs()
          if (!this.query.trim()) {
            Column({ space: 4 }) {
              Text('发现好片').fontSize(Ui.fs(Ui.fsDisplay(this.viewportWidth), this.fontScale)).fontWeight(FontWeight.Bold).fontColor(this.ink())
              Text('电影 · 剧集 · 动漫 · 综艺，一键发现想看的内容')
                .fontSize(Ui.fs(Ui.fsCaption(this.viewportWidth), this.fontScale)).fontColor(this.muted())
            }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: '4vp', bottom: '2vp' })
            this.categoryTabs()
            this.recommendationSection()
            this.keywordSection('快捷热搜', this.hotWords)
            if (this.records.length) { this.keywordSection('最近搜索', this.records) }
          }
          this.resultList(listScroller, scrollPrefix + '-results')
        }.padding({
          top: '12vp',
          left: Ui.gutter(this.viewportWidth),
          right: Ui.gutter(this.viewportWidth),
          bottom: (Number.isFinite(this.navClearance) ? Math.max(0, this.navClearance) : 186) + 'vp'
        }).width('100%')
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
        .onScrollStart(() => { NavigationScroll.begin('search', scrollPrefix + '-content', pageScroller); })
        .onDidScroll((_xOffset: number, _yOffset: number, scrollState: ScrollState) => {
        NavigationScroll.report('search', scrollPrefix + '-content', pageScroller, scrollState);
      })
        .onScrollStop(() => { NavigationScroll.end('search', scrollPrefix + '-content', pageScroller); })
        .padding({ bottom: '0vp' }).margin({ bottom: '0vp' })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }.width('100%').height('100%').padding('0vp').margin('0vp')
      .expandSafeArea([SafeAreaType.SYSTEM],
      [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
  }
  // 抽屉与遮罩也撑满沉浸区域，底部不添加导航栏或手势条防遮挡空间。
  @Builder private drawerCover() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%').height('100%')
        .linearGradient({
          angle: 180,
          colors: [[Ui.pageBg(this.dark), 0], [Ui.pageBgAlt(this.dark), 1]]
        })
      AuroraBackdrop({ intensity: this.dark ? 1 : 0.9 })
      this.searchContent(this.coverContentScroller, this.coverResultScroller, 'cover')
      Column().width('100%').height('100%').backgroundColor(Ui.scrim(this.dark))
        .expandSafeArea([SafeAreaType.SYSTEM],
        [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
        .onClick(() => { this.drawerOpen = false; })
        .transition(TransitionEffect.OPACITY.animation({ duration: 240 }))
      this.sourceDrawer()
    }.width('100%').height('100%').padding('0vp').margin('0vp')
      .backgroundColor(Ui.pageBg(this.dark))
      .expandSafeArea([SafeAreaType.SYSTEM],
      [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
  }
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 底层：页面底色渐变 + 极光柔光
      Column()
        .width('100%').height('100%')
        .linearGradient({
          angle: 180,
          colors: [[Ui.pageBg(this.dark), 0], [Ui.pageBgAlt(this.dark), 1]]
        })
      AuroraBackdrop({ intensity: this.dark ? 1 : 0.9 })
      this.searchContent(this.contentScroller, this.resultScroller, 'page')
    }.width('100%').height('100%').padding('0vp').margin('0vp')
      .backgroundColor(Ui.pageBg(this.dark))
      .expandSafeArea([SafeAreaType.SYSTEM],
      [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
      .bindContentCover(this.drawerOpen, this.drawerCover(), { modalTransition: ModalTransition.NONE })
      .onAreaChange((_old: Area, area: Area) => { this.updateViewportWidth(area); })
  }
}
