import { http } from '@kit.NetworkKit';
import { Logger } from './Logger';

export interface CategoryFilters {
  xingshi: string | null;
  leixing: string;
  diqu: string;
  shijian: string;
  paixin: string;
}

export interface CategoryVideo {
  key: string;
  img: string;
  upda: string;
  title: string;
  id: string;
  actor: string;
  intro: string;
  date: string;
  rating: number | null;
  area: string;
  type: string;
}

export interface CategoryBatch {
  size: number;
  sourceCount: number;
  videos: CategoryVideo[];
  totalNum?: number;
}

interface CategorySource {
  id?: string | number | null;
  title?: string | null;
  name?: string | null;
  actor?: string | string[] | null;
  intro?: string | null;
  date?: string | number | null;
  area?: string | string[] | null;
  type?: string | string[] | null;
  img?: string | null;
  img_url?: string | null;
  imgh_url?: string | null;
  cover?: string | null;
  pic?: string | null;
  rating?: string | number | null;
  da?: string | number | null;
  update?: string | number | null;
}

interface CategoryMetadata {
  total_num?: string | number;
  size?: string | number;
}

interface CategoryResponse extends CategoryMetadata {
  jo?: CategoryResponse;
  videoshow?: CategoryResponse;
  data?: CategoryResponse | CategorySource[];
  result?: CategoryResponse | CategorySource[];
  list?: CategoryMetadata | CategorySource[];
  videos?: CategorySource[];
}

interface CategoryEndpoint {
  address: string;
  channel: string;
}

interface CategoryQueryParameter {
  key: string;
  value: string;
}

// 与搜索业务完全独立；首次加载和分页共用同一组筛选、解析与 yin 转换。
export class CategoryService {
  private static endpoint(form: string | null): CategoryEndpoint {
    switch (form) {
      case '电视剧':
        return { address: 'http://v.baidu.com/commonapi/tvplay2level/', channel: 'tvplay' };
      case '动漫':
        return { address: 'http://v.baidu.com/commonapi/comic2level/', channel: 'comic' };
      case '综艺':
        return { address: 'http://v.baidu.com/commonapi/tvshow2level/', channel: 'tvshow' };
      default:
        return { address: 'http://v.baidu.com/commonapi/movie2level/', channel: 'movie' };
    }
  }

  private static appendFilter(parameters: CategoryQueryParameter[], key: string, value: string): void {
    const effectiveValue: string = value.trim();
    // “全部”和空选项不创建 query key，也不保留 actor=/prop= 等空参数。
    if (effectiveValue && effectiveValue !== '全部') {
      parameters.push({ key: key, value: effectiveValue });
    }
  }

  private static queryParameters(filters: CategoryFilters, page: number): CategoryQueryParameter[] {
    const endpoint: CategoryEndpoint = CategoryService.endpoint(filters.xingshi);
    const pageNumber: number = Number.isFinite(page) ? Math.max(1, Math.floor(page)) : 1;
    const parameters: CategoryQueryParameter[] = [{ key: 'filter', value: 'true' }];
    CategoryService.appendFilter(parameters, 'type', filters.leixing);
    CategoryService.appendFilter(parameters, 'area', filters.diqu);
    CategoryService.appendFilter(parameters, 'start', filters.shijian);
    CategoryService.appendFilter(parameters, 'order', filters.paixin);
    parameters.push({ key: 'channel', value: endpoint.channel });
    parameters.push({ key: 'pn', value: String(pageNumber) });
    return parameters;
  }

  static address(filters: CategoryFilters, page: number): string {
    const endpoint: CategoryEndpoint = CategoryService.endpoint(filters.xingshi);
    const parameters: CategoryQueryParameter[] = CategoryService.queryParameters(filters, page);
    const encodedParameters: string[] = [];
    for (let index: number = 0; index < parameters.length; index++) {
      const queryParameter: CategoryQueryParameter = parameters[index];
      encodedParameters.push(encodeURIComponent(queryParameter.key) + '=' + encodeURIComponent(queryParameter.value));
    }
    return endpoint.address + '?' + encodedParameters.join('&');
  }

  private static text(value: string | number | null | undefined): string {
    if (typeof value !== 'string' && typeof value !== 'number') {
      return '';
    }
    return String(value).trim();
  }

  private static labels(value: string | string[] | null | undefined): string {
    if (typeof value === 'string') {
      return value.trim();
    }
    if (!Array.isArray(value)) {
      return '';
    }
    const labels: string[] = [];
    for (let index: number = 0; index < value.length; index++) {
      const label: string = CategoryService.text(value[index]);
      if (label) {
        labels.push(label);
      }
    }
    return labels.join('、');
  }

  private static rating(value: string | number | null | undefined): number | null {
    const scoreText: string = CategoryService.text(value);
    if (!scoreText) {
      return null;
    }
    const score: number = Number(scoreText);
    if (!Number.isFinite(score) || score <= 0 || score > 100) {
      Logger.warn('CategoryService', '影片评分缺失或不在百分制范围，使用暂无评分占位，rating=' + scoreText);
      return null;
    }
    // 精确按百分制除以 10；显示时再由卡片保留一位小数，不提前舍入接口评分。
    return score / 10;
  }

  // 保留 upda 对旧排序逻辑的兼容，卡片独立使用转换后的 rating。
  private static yin(item: CategorySource, order: string, page: number, index: number): CategoryVideo {
    const title: string = CategoryService.text(item.title) || CategoryService.text(item.name) || '未命名影片';
    const img: string = CategoryService.text(item.imgh_url) || CategoryService.text(item.img) ||
      CategoryService.text(item.img_url) || CategoryService.text(item.cover) || CategoryService.text(item.pic);
    const rating: number | null = CategoryService.rating(item.rating);
    const ratingText: string = rating === null ? '暂无评分' : rating.toFixed(1);
    const upda: string = order === 'rating' ? ratingText :
      CategoryService.text(item.da) || CategoryService.text(item.update) || ratingText;
    const id: string = CategoryService.text(item.id);
    const rawDate: string = CategoryService.text(item.date);
    const date: string = /^\d{4}/.test(rawDate) ? rawDate.substring(0, 4) : rawDate || '年份未知';
    return {
      key: String(page) + '-' + String(index) + '-' + id,
        img: img,
        upda: upda,
        title: title,
        id: id,
        actor: CategoryService.labels(item.actor) || '暂无演员信息',
        intro: CategoryService.text(item.intro) || '暂无简介',
        date: date,
        rating: rating,
        area: CategoryService.labels(item.area) || '地区未知',
        type: CategoryService.labels(item.type) || '类型未知'
    };
  }

  private static appendResponse(nodes: CategoryResponse[], value: CategoryResponse | CategorySource[] | undefined): void {
    if (value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value)) {
      nodes.push(value as CategoryResponse);
    }
  }

  private static responseNodes(payload: CategoryResponse): CategoryResponse[] {
    if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
      throw new Error('分类接口返回体不是预期的 JSON 对象');
    }
    const nodes: CategoryResponse[] = [payload];
    // 根返回体已经明确无结果时，不再校验包装层、size 或影片数组。
    if (CategoryService.count(payload.total_num, 'total_num') === 0) {
      return nodes;
    }
    // list 对象只兼容数量元数据，不读取 list.videos。
    for (let index: number = 0; index < nodes.length; index++) {
      if (index >= 32) {
        throw new Error('分类接口返回体包装层级不符合预期');
      }
      const node: CategoryResponse = nodes[index];
      CategoryService.appendResponse(nodes, node.jo);
      CategoryService.appendResponse(nodes, node.videoshow);
      CategoryService.appendResponse(nodes, node.data);
      CategoryService.appendResponse(nodes, node.result);
    }
    return nodes;
  }

  private static declaredTotal(nodes: CategoryResponse[]): string | number | undefined {
    for (let index: number = 0; index < nodes.length; index++) {
      const node: CategoryResponse = nodes[index];
      if (node.total_num !== undefined) {
        return node.total_num;
      }
    }
    for (let index: number = 0; index < nodes.length; index++) {
      const list: CategoryMetadata | CategorySource[] | undefined = nodes[index].list;
      if (list !== undefined && list !== null && typeof list === 'object' && !Array.isArray(list)) {
        const metadata: CategoryMetadata = list as CategoryMetadata;
        if (metadata.total_num !== undefined) {
          return metadata.total_num;
        }
      }
    }
    return undefined;
  }

  private static declaredSize(nodes: CategoryResponse[]): string | number | undefined {
    for (let index: number = 0; index < nodes.length; index++) {
      const node: CategoryResponse = nodes[index];
      const list: CategoryMetadata | CategorySource[] | undefined = node.list;
      if (list !== undefined && list !== null && typeof list === 'object' && !Array.isArray(list)) {
        const metadata: CategoryMetadata = list as CategoryMetadata;
        if (metadata.size !== undefined) {
          return metadata.size;
        }
      }
      if (node.size !== undefined) {
        return node.size;
      }
    }
    return undefined;
  }

  private static count(value: string | number | undefined, field: string): number {
    if (value === undefined) {
      return Number.NaN;
    }
    if ((typeof value !== 'number' && typeof value !== 'string') || String(value).trim() === '') {
      throw new Error('分类接口 ' + field + ' 类型不符合预期');
    }
    const result: number = Number(value);
    if (!Number.isFinite(result) || !Number.isInteger(result) || result < (field === 'size' ? -1 : 0)) {
      throw new Error('分类接口 ' + field + ' 数量不符合预期');
    }
    return result;
  }

  private static videoShowNode(payload: CategoryResponse, nodes: CategoryResponse[]): CategoryResponse | undefined {
    // 优先使用明确的 videoshow 节点，保留原有 jo/data/result 包装兼容。
    for (let index: number = 0; index < nodes.length; index++) {
      const candidate: CategoryResponse | undefined = nodes[index].videoshow;
      if (candidate !== undefined && candidate !== null && typeof candidate === 'object' && !Array.isArray(candidate)) {
        return candidate;
      }
    }
    // 返回体本身就是 videoshow 时，直接读取根节点 videos；不使用其他包装层或 list 中的数组。
    return Array.isArray(payload.videos) ? payload : undefined;
  }

  private static parse(payload: CategoryResponse, filters: CategoryFilters, page: number): CategoryBatch {
    const nodes: CategoryResponse[] = CategoryService.responseNodes(payload);
    const totalValue: number = CategoryService.count(CategoryService.declaredTotal(nodes), 'total_num');
    if (totalValue === 0) {
      return { size: 0, sourceCount: 0, videos: [], totalNum: 0 };
    }
    const sizeValue: number = CategoryService.count(CategoryService.declaredSize(nodes), 'size');
    const totalNum: number | undefined = Number.isFinite(totalValue) ? totalValue : undefined;
    // 保留 size=-1 空状态、size=0 分页结束的语义。
    if (sizeValue === -1 || sizeValue === 0) {
      return { size: sizeValue, sourceCount: 0, videos: [], totalNum: totalNum };
    }
    const videoShow: CategoryResponse | undefined = CategoryService.videoShowNode(payload, nodes);
    if (videoShow === undefined || !Array.isArray(videoShow.videos)) {
      throw new Error('分类接口返回 JSON 结构不符合预期：缺少 videoshow.videos 影片数组');
    }
    const sources: CategorySource[] = videoShow.videos;
    const videos: CategoryVideo[] = [];
    for (let index: number = 0; index < sources.length; index++) {
      const source: CategorySource = sources[index];
      if (!source) {
        Logger.warn('CategoryService', '影片条目为空，跳过该条目，索引=' + index);
        continue;
      }
      if (typeof source !== 'object' || Array.isArray(source)) {
        throw new Error('分类接口影视数组条目格式错误，索引=' + index);
      }
      videos.push(CategoryService.yin(source, filters.paixin, page, index));
    }
    return {
      size: sources.length === 0 ? 0 : Number.isFinite(sizeValue) ? sizeValue : sources.length,
        sourceCount: sources.length,
        videos: videos,
        totalNum: totalNum
    };
  }

  static async load(request: http.HttpRequest, filters: CategoryFilters, page: number): Promise<CategoryBatch> {
    const requestUrl: string = CategoryService.address(filters, page);
    const effectiveParameters: CategoryQueryParameter[] = CategoryService.queryParameters(filters, page);
    Logger.info('CategoryService', '开始请求分类接口，拼接完成完整URL：' + requestUrl +
    '，请求参数（已过滤全部及空值）：' + JSON.stringify(effectiveParameters) +
    '，形式xingshi=' + String(filters.xingshi));
    let responseBody: string = '（尚未收到返回报文）';
    try {
      const response: http.HttpResponse = await request.request(requestUrl, {
        method: http.RequestMethod.GET,
          connectTimeout: 10000,
          readTimeout: 15000,
          expectDataType: http.HttpDataType.STRING
      });
      responseBody = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      // 不截断返回报文，完整保留用于排查解析结构的 JSON 摘要和请求 URL。
      Logger.info('CategoryService', '分类接口返回JSON摘要（完整返回报文），本次请求完整URL：' + requestUrl +
      '，HTTP状态码=' + response.responseCode + '，返回报文：' + responseBody);
      if (response.responseCode !== 200) {
        throw new Error('分类接口 HTTP ' + response.responseCode);
      }
      const payload: CategoryResponse = JSON.parse(responseBody) as CategoryResponse;
      const batch: CategoryBatch = CategoryService.parse(payload, filters, page);
      Logger.info('CategoryService', '分类接口请求成功，返回条目数量：' + batch.videos.length +
      '，size=' + batch.size + '，total_num=' + String(batch.totalNum) +
      (batch.totalNum === 0 ? '，暂无匹配影视资源' : '') + '，本次请求完整URL：' + requestUrl);
      return batch;
    } catch (error) {
      Logger.error('CategoryService', '分类接口请求失败，本次请求完整URL：' + requestUrl +
      '，返回报文：' + responseBody + '，错误信息：' + String(error));
      // ArkTS 仅允许抛出 Error；保留已有 Error 的堆栈，其他异常转换后继续交给页面处理。
      if (error instanceof Error) {
        const requestError: Error = error as Error;
        throw requestError;
      }
      throw new Error(String(error));
    }
  }
}
