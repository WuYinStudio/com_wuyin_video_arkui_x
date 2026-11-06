/**
 * 节日主题：分享二维码「节日」版式按当天日期切换配色、装饰与祝福语。
 *
 * 说明：
 * - 公历节日用 MM-DD 规则，农历节日（春节/元宵/端午/七夕/中秋/重阳/除夕）用
 *   2025–2030 的公历日期表，超出范围的年份按「无节日」处理，走默认红金元素；
 * - 所有配色都保证深色底 + 浅色文字（海报文字对比度足够）。
 */
class FestivalRule {
  /** 匹配键：公历 MM-DD，农历节日为 YYYY-MM-DD。 */
  key: string;
  /** 主题标识，仅用于日志。 */
  id: string;
  /** 节日名称，例如「春节」。 */
  name: string;
  /** 海报上的祝福语，例如「新春大吉」。 */
  greeting: string;
  bgFrom: string;
  bgTo: string;
  accent: string;
  /** 装饰元素：lantern / moon / snow / heart / star / firework / leaf。 */
  motif: string;

  constructor(key: string, id: string, name: string, greeting: string, bgFrom: string, bgTo: string,
    accent: string, motif: string) {
    this.key = key;
    this.id = id;
    this.name = name;
    this.greeting = greeting;
    this.bgFrom = bgFrom;
    this.bgTo = bgTo;
    this.accent = accent;
    this.motif = motif;
  }
}

export class FestivalTheme {
  id: string = 'default';
  name: string = '节日';
  greeting: string = '';
  bgFrom: string = '#C11B22';
  bgTo: string = '#6E0C11';
  accent: string = '#FFD98A';
  motif: string = 'lantern';

  /** 公历节日：MM-DD。 */
  private static readonly SOLAR: FestivalRule[] = [
    new FestivalRule('01-01', 'new-year', '元旦', '新年快乐', '#B0121C', '#5E0810', '#FFD98A', 'firework'),
    new FestivalRule('02-14', 'valentine', '情人节', '甜蜜相伴', '#B3124B', '#43081F', '#FFC6D9', 'heart'),
    new FestivalRule('03-08', 'women', '妇女节', '美丽常在', '#A61B5C', '#3C0A22', '#FFD1E6', 'heart'),
    new FestivalRule('05-01', 'labour', '劳动节', '劳动节快乐', '#B6530F', '#3D1A05', '#FFD79A', 'star'),
    new FestivalRule('06-01', 'children', '儿童节', '节日快乐', '#1B5FA6', '#0A2440', '#FFE28A', 'star'),
    new FestivalRule('09-10', 'teacher', '教师节', '感念师恩', '#8A5A12', '#2E1D06', '#FFE0A3', 'star'),
    new FestivalRule('10-01', 'national', '国庆节', '举国同庆', '#C11B22', '#62090E', '#FFD98A', 'firework'),
    new FestivalRule('12-24', 'xmas-eve', '平安夜', '平安夜快乐', '#0F4A2E', '#052014', '#D9F3C7', 'snow'),
    new FestivalRule('12-25', 'xmas', '圣诞节', '圣诞快乐', '#0E5233', '#051F13', '#FFE0A3', 'snow'),
    new FestivalRule('12-31', 'new-year-eve', '跨年', '新年快乐', '#3B1D6E', '#160A2D', '#FFD98A', 'firework')
  ];

  /** 农历节日的公历日期（2025–2030）：key 为 YYYY-MM-DD。 */
  private static readonly LUNAR: FestivalRule[] = [
    // 除夕
    new FestivalRule('2025-01-28', 'eve', '除夕', '除夕快乐', '#B0121C', '#560810', '#FFD98A', 'lantern'),
    new FestivalRule('2026-02-16', 'eve', '除夕', '除夕快乐', '#B0121C', '#560810', '#FFD98A', 'lantern'),
    new FestivalRule('2027-02-05', 'eve', '除夕', '除夕快乐', '#B0121C', '#560810', '#FFD98A', 'lantern'),
    new FestivalRule('2028-01-25', 'eve', '除夕', '除夕快乐', '#B0121C', '#560810', '#FFD98A', 'lantern'),
    new FestivalRule('2029-02-12', 'eve', '除夕', '除夕快乐', '#B0121C', '#560810', '#FFD98A', 'lantern'),
    new FestivalRule('2030-02-02', 'eve', '除夕', '除夕快乐', '#B0121C', '#560810', '#FFD98A', 'lantern'),
    // 春节
    new FestivalRule('2025-01-29', 'spring', '春节', '新春大吉', '#C11B22', '#6E0C11', '#FFD98A', 'lantern'),
    new FestivalRule('2026-02-17', 'spring', '春节', '新春大吉', '#C11B22', '#6E0C11', '#FFD98A', 'lantern'),
    new FestivalRule('2027-02-06', 'spring', '春节', '新春大吉', '#C11B22', '#6E0C11', '#FFD98A', 'lantern'),
    new FestivalRule('2028-01-26', 'spring', '春节', '新春大吉', '#C11B22', '#6E0C11', '#FFD98A', 'lantern'),
    new FestivalRule('2029-02-13', 'spring', '春节', '新春大吉', '#C11B22', '#6E0C11', '#FFD98A', 'lantern'),
    new FestivalRule('2030-02-03', 'spring', '春节', '新春大吉', '#C11B22', '#6E0C11', '#FFD98A', 'lantern'),
    // 元宵
    new FestivalRule('2025-02-12', 'lantern-festival', '元宵节', '元宵团圆', '#B3251F', '#5C0E0C', '#FFDCA8', 'lantern'),
    new FestivalRule('2026-03-03', 'lantern-festival', '元宵节', '元宵团圆', '#B3251F', '#5C0E0C', '#FFDCA8', 'lantern'),
    new FestivalRule('2027-02-20', 'lantern-festival', '元宵节', '元宵团圆', '#B3251F', '#5C0E0C', '#FFDCA8', 'lantern'),
    new FestivalRule('2028-02-09', 'lantern-festival', '元宵节', '元宵团圆', '#B3251F', '#5C0E0C', '#FFDCA8', 'lantern'),
    new FestivalRule('2029-02-27', 'lantern-festival', '元宵节', '元宵团圆', '#B3251F', '#5C0E0C', '#FFDCA8', 'lantern'),
    new FestivalRule('2030-02-17', 'lantern-festival', '元宵节', '元宵团圆', '#B3251F', '#5C0E0C', '#FFDCA8', 'lantern'),
    // 端午
    new FestivalRule('2025-05-31', 'dragon-boat', '端午节', '端午安康', '#0F5B3E', '#04291B', '#F3E0A6', 'leaf'),
    new FestivalRule('2026-06-19', 'dragon-boat', '端午节', '端午安康', '#0F5B3E', '#04291B', '#F3E0A6', 'leaf'),
    new FestivalRule('2027-06-09', 'dragon-boat', '端午节', '端午安康', '#0F5B3E', '#04291B', '#F3E0A6', 'leaf'),
    new FestivalRule('2028-05-28', 'dragon-boat', '端午节', '端午安康', '#0F5B3E', '#04291B', '#F3E0A6', 'leaf'),
    new FestivalRule('2029-06-16', 'dragon-boat', '端午节', '端午安康', '#0F5B3E', '#04291B', '#F3E0A6', 'leaf'),
    new FestivalRule('2030-06-05', 'dragon-boat', '端午节', '端午安康', '#0F5B3E', '#04291B', '#F3E0A6', 'leaf'),
    // 七夕
    new FestivalRule('2025-08-29', 'qixi', '七夕', '七夕甜蜜', '#7A1C5A', '#2A0720', '#FFC6E0', 'heart'),
    new FestivalRule('2026-08-19', 'qixi', '七夕', '七夕甜蜜', '#7A1C5A', '#2A0720', '#FFC6E0', 'heart'),
    new FestivalRule('2027-08-08', 'qixi', '七夕', '七夕甜蜜', '#7A1C5A', '#2A0720', '#FFC6E0', 'heart'),
    new FestivalRule('2028-08-26', 'qixi', '七夕', '七夕甜蜜', '#7A1C5A', '#2A0720', '#FFC6E0', 'heart'),
    new FestivalRule('2029-08-16', 'qixi', '七夕', '七夕甜蜜', '#7A1C5A', '#2A0720', '#FFC6E0', 'heart'),
    new FestivalRule('2030-08-05', 'qixi', '七夕', '七夕甜蜜', '#7A1C5A', '#2A0720', '#FFC6E0', 'heart'),
    // 中秋
    new FestivalRule('2025-10-06', 'mid-autumn', '中秋节', '中秋团圆', '#1E2A5A', '#080E26', '#FFD98A', 'moon'),
    new FestivalRule('2026-09-25', 'mid-autumn', '中秋节', '中秋团圆', '#1E2A5A', '#080E26', '#FFD98A', 'moon'),
    new FestivalRule('2027-09-15', 'mid-autumn', '中秋节', '中秋团圆', '#1E2A5A', '#080E26', '#FFD98A', 'moon'),
    new FestivalRule('2028-10-03', 'mid-autumn', '中秋节', '中秋团圆', '#1E2A5A', '#080E26', '#FFD98A', 'moon'),
    new FestivalRule('2029-09-22', 'mid-autumn', '中秋节', '中秋团圆', '#1E2A5A', '#080E26', '#FFD98A', 'moon'),
    new FestivalRule('2030-09-12', 'mid-autumn', '中秋节', '中秋团圆', '#1E2A5A', '#080E26', '#FFD98A', 'moon'),
    // 重阳
    new FestivalRule('2025-10-29', 'double-ninth', '重阳节', '重阳安康', '#7A4A12', '#241405', '#FFE0A3', 'leaf'),
    new FestivalRule('2026-10-18', 'double-ninth', '重阳节', '重阳安康', '#7A4A12', '#241405', '#FFE0A3', 'leaf'),
    new FestivalRule('2027-10-08', 'double-ninth', '重阳节', '重阳安康', '#7A4A12', '#241405', '#FFE0A3', 'leaf'),
    new FestivalRule('2028-10-26', 'double-ninth', '重阳节', '重阳安康', '#7A4A12', '#241405', '#FFE0A3', 'leaf'),
    new FestivalRule('2029-10-16', 'double-ninth', '重阳节', '重阳安康', '#7A4A12', '#241405', '#FFE0A3', 'leaf'),
    new FestivalRule('2030-10-05', 'double-ninth', '重阳节', '重阳安康', '#7A4A12', '#241405', '#FFE0A3', 'leaf')
  ];

  private static pad(value: number): string {
    return value < 10 ? '0' + String(value) : String(value);
  }

  /** 当天节日主题；没有节日时返回默认红金主题（motif = lantern）。 */
  static current(now: Date = new Date()): FestivalTheme {
    try {
      const year: number = now.getFullYear();
      const month: number = now.getMonth() + 1;
      const day: number = now.getDate();
      const fullKey: string = String(year) + '-' + FestivalTheme.pad(month) + '-' + FestivalTheme.pad(day);
      const shortKey: string = FestivalTheme.pad(month) + '-' + FestivalTheme.pad(day);
      const theme: FestivalTheme = new FestivalTheme();
      const lunar: FestivalRule | undefined = FestivalTheme.LUNAR.find((rule: FestivalRule) => rule.key === fullKey);
      const solar: FestivalRule | undefined = lunar !== undefined ? undefined :
        FestivalTheme.SOLAR.find((rule: FestivalRule) => rule.key === shortKey);
      const matched: FestivalRule | undefined = lunar !== undefined ? lunar : solar;
      if (matched === undefined) { return theme; }
      theme.id = matched.id;
      theme.name = matched.name;
      theme.greeting = matched.greeting;
      theme.bgFrom = matched.bgFrom;
      theme.bgTo = matched.bgTo;
      theme.accent = matched.accent;
      theme.motif = matched.motif;
      return theme;
    } catch (_) {
      return new FestivalTheme();
    }
  }
}
