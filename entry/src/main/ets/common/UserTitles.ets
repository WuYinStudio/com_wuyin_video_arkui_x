/**
 * 聊天室用户等级头衔（无音影视主题）。
 *
 * 等级来源：消息里的 grade 字段（形如 "Lv.3" / "3级" / "3"）；解析不到数字时，
 * 用账号做稳定哈希兜底，保证同一个人每次都显示同一个头衔，不会随机跳变。
 * 第 10 级起使用"无音殿堂"系列，作为最高荣誉。
 */
export class UserTitle {
  level: number = 1;
  name: string = '';
  /** 头衔配色（跟随深浅色，这里给两端色值）。 */
  darkColor: string = '#8FB4FF';
  lightColor: string = '#2F5FD0';
  /** 是否为高等级（VIP 质感）头衔。 */
  honor: boolean = false;
}

export class UserTitles {
  /** 完整头衔表：1~12 级，全部围绕"看片 / 剪辑 / 放映 / 制作"。 */
  static readonly TABLE: UserTitle[] = UserTitles.build();

  private static build(): UserTitle[] {
    const list: UserTitle[] = [];
    // 1~12 级：手写，围绕"看片 → 拆解 → 剪辑 → 导演 → 殿堂"的成长线。
    list.push(UserTitles.item(1, '光影新人', '#8FB4FF', '#2F5FD0', false));
    list.push(UserTitles.item(2, '观影学徒', '#8FB4FF', '#2F5FD0', false));
    list.push(UserTitles.item(3, '银幕常客', '#7FD8C6', '#0F7C63', false));
    list.push(UserTitles.item(4, '片单收藏家', '#7FD8C6', '#0F7C63', false));
    list.push(UserTitles.item(5, '影评笔杆', '#9BD37F', '#3B7A18', false));
    list.push(UserTitles.item(6, '分镜拆解师', '#9BD37F', '#3B7A18', false));
    list.push(UserTitles.item(7, '剪辑好手', '#FFCF87', '#B4740C', true));
    list.push(UserTitles.item(8, '放映室主理人', '#FFCF87', '#B4740C', true));
    list.push(UserTitles.item(9, '光影导演', '#FFB36B', '#B4560C', true));
    list.push(UserTitles.item(10, '无音殿堂', '#FF9BB3', '#B01B3C', true));
    list.push(UserTitles.item(11, '无音殿堂 · 金', '#FFE08A', '#9A6A00', true));
    list.push(UserTitles.item(12, '无音殿堂 · 传奇', '#FFFFFF', '#000000', true));
    // 13~100 级：九大进阶档，每档 10 个序号（Ⅰ~Ⅹ），共 88 个，补足到 100 级。
    const tiers: string[] = [
      '银幕守望者', '光影造梦师', '星海放映家', '无音剪辑圣手', '传奇影评人',
      '影视掌灯人', '无音殿堂 · 殿堂级', '无音殿堂 · 史诗'
    ];
    const dark: string[] = ['#9BB8FF', '#8FE3D2', '#A6E07F', '#FFD08A', '#FF9BB3', '#C7A6FF', '#FFE08A', '#FFC46B', '#FFFFFF'];
    const light: string[] = ['#2F5FD0', '#0F7C63', '#3B7A18', '#B4740C', '#B01B3C', '#6B3FBF', '#9A6A00', '#B4560C', '#000000'];
    const numerals: string[] = ['Ⅰ', 'Ⅱ', 'Ⅲ', 'Ⅳ', 'Ⅴ', 'Ⅵ', 'Ⅶ', 'Ⅷ', 'Ⅸ', 'Ⅹ'];
    let level: number = 13;
    for (let tier: number = 0; tier < tiers.length && level <= 100; tier++) {
      for (let index: number = 0; index < numerals.length && level <= 100; index++) {
        list.push(UserTitles.item(level, tiers[tier] + ' ' + numerals[index],
          dark[Math.min(dark.length - 1, tier)], light[Math.min(light.length - 1, tier)], true));
        level++;
      }
    }
    // 93~100 级：终章「无音殿堂 · 虚无」Ⅲ~Ⅹ，第 100 级固定为 Ⅹ。
    const finalNumerals: string[] = ['Ⅲ', 'Ⅳ', 'Ⅴ', 'Ⅵ', 'Ⅶ', 'Ⅷ', 'Ⅸ', 'Ⅹ'];
    for (let index: number = 0; index < finalNumerals.length; index++) {
      const target: number = 93 + index;
      list[target - 1] = UserTitles.item(target, '无音殿堂 · 虚无 ' + finalNumerals[index], '#FFFFFF', '#000000', true);
    }
    return list;
  }

  private static item(level: number, name: string, dark: string, light: string, honor: boolean): UserTitle {
    const title: UserTitle = new UserTitle();
    title.level = level;
    title.name = name;
    title.darkColor = dark;
    title.lightColor = light;
    title.honor = honor;
    return title;
  }

  /** 从 grade / 账号解析等级：先找 grade 里的数字，其次按账号稳定哈希（1~6）。 */
  static levelOf(grade: string, account: string): number {
    const parsed: number = UserTitles.numberIn(grade);
    if (parsed > 0) {
      return Math.max(1, Math.min(UserTitles.TABLE.length, parsed));
    }
    return UserTitles.hashLevel(account);
  }

  private static numberIn(text: string): number {
    if (!text) {
      return 0;
    }
    const match: RegExpMatchArray | null = text.match(/\d+/);
    if (match === null) {
      return 0;
    }
    const value: number = Number(match[0]);
    return Number.isFinite(value) ? Math.trunc(value) : 0;
  }

  /** 没有等级字段时的稳定兜底：账号哈希映射到 1~6 级，避免高位头衔烂大街。 */
  private static hashLevel(account: string): number {
    if (!account) {
      return 1;
    }
    let hash: number = 0;
    for (let index: number = 0; index < account.length; index++) {
      hash = (Math.imul(31, hash) + account.charCodeAt(index)) | 0;
    }
    const positive: number = Math.abs(hash);
    return 1 + positive % 6;
  }

  static titleOf(grade: string, account: string): UserTitle {
    const level: number = UserTitles.levelOf(grade, account);
    return UserTitles.TABLE[Math.max(0, Math.min(UserTitles.TABLE.length - 1, level - 1))];
  }

  static nameOf(grade: string, account: string): string {
    return UserTitles.titleOf(grade, account).name;
  }

  static colorOf(grade: string, account: string, dark: boolean): string {
    const title: UserTitle = UserTitles.titleOf(grade, account);
    return dark ? title.darkColor : title.lightColor;
  }

  /** 头衔标签文案：等级 + 名称，例如 "Lv.7 剪辑好手"。 */
  static badgeOf(grade: string, account: string): string {
    const title: UserTitle = UserTitles.titleOf(grade, account);
    return 'Lv.' + String(title.level) + ' ' + title.name;
  }

  /**
   * 等级经验阈值：下标 = 等级-1，值为升到该等级所需的累计 exp。
   * 与 echouserdata.php 返回的 exp 对应，做到"等级 = 真实经验"，而不是随机兜底。
   */
  static readonly EXP_STEPS: number[] = UserTitles.buildExpSteps();
  /** 1~100 级的累计经验：前 12 级手工设定，之后每级 +2000 并逐档加速，满级 100 约 60 万经验。 */
  private static buildExpSteps(): number[] {
    const steps: number[] = [0, 50, 150, 350, 700, 1200, 2000, 3200, 5000, 8000, 12000, 20000];
    let current: number = 20000;
    for (let level: number = 13; level <= 100; level++) {
      current += 2000 + (level - 12) * 60;
      steps.push(current);
    }
    return steps;
  }


  /** 由经验值换算等级（1~12）。 */
  static levelFromExp(exp: number): number {
    const value: number = Number.isFinite(exp) ? Math.max(0, Math.floor(exp)) : 0;
    let level: number = 1;
    for (let index = 0; index < UserTitles.EXP_STEPS.length; index++) {
      if (value >= UserTitles.EXP_STEPS[index]) {
        level = index + 1;
      }
    }
    return level;
  }

  /** 升级到下一级还差多少经验；满级返回 -1。 */
  static expToNext(exp: number): number {
    const level: number = UserTitles.levelFromExp(exp);
    if (level >= UserTitles.EXP_STEPS.length) {
      return -1;
    }
    return Math.max(0, UserTitles.EXP_STEPS[level] - Math.max(0, Math.floor(exp)));
  }

  /** 由经验值直接取头衔（账号资料页、我的页面顶部用）。 */
  static titleOfExp(exp: number): UserTitle {
    const level: number = UserTitles.levelFromExp(exp);
    return UserTitles.TABLE[Math.max(0, Math.min(UserTitles.TABLE.length - 1, level - 1))];
  }

  static badgeOfExp(exp: number): string {
    const title: UserTitle = UserTitles.titleOfExp(exp);
    return 'Lv.' + String(title.level) + ' ' + title.name;
  }

  /**
   * 头衔渐变（高等级用）：返回 [起始色, 结束色, 文字色]。
   * 13 级起按档位给出双色渐变，用于胶囊底色；1~12 级返回单色（两次相同）。
   */
  static gradientOf(grade: string, account: string): string[] {
    const title: UserTitle = UserTitles.titleOf(grade, account);
    const level: number = title.level;
    if (level < 13) {
      return [title.darkColor, title.darkColor, title.lightColor];
    }
    const palettes: string[][] = [
      ['#2F5FD0', '#7FB2FF', '#FFFFFF'],
      ['#0F7C63', '#57D8B5', '#FFFFFF'],
      ['#3B7A18', '#9BE07F', '#0B2400'],
      ['#B4740C', '#FFD08A', '#3A2200'],
      ['#B01B3C', '#FF9BB3', '#FFFFFF'],
      ['#6B3FBF', '#C7A6FF', '#FFFFFF'],
      ['#9A6A00', '#FFE08A', '#3A2600'],
      ['#B4560C', '#FFC46B', '#FFFFFF'],
      ['#111111', '#8A8A8A', '#FFFFFF']
    ];
    const tier: number = Math.min(palettes.length - 1, Math.floor((level - 13) / 10));
    return palettes[tier];
  }
}
