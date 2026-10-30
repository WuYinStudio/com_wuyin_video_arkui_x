import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

/** 一条金币流水。 */
export class WalletFlow {
  time: string = '';
  title: string = '';
  amount: number = 0;
  note: string = '';
}

/** VIP 档位（价格与天数都是客户端沙箱配置，真实下单需接支付接口）。 */
export class VipPlan {
  id: string = '';
  name: string = '';
  days: number = 0;
  price: number = 0;
  desc: string = '';
}

/** 榜单一行。 */
export class RankRow {
  name: string = '';
  value: number = 0;
  extra: string = '';
}

/** 本地存档结构（一次性存成一个 JSON 字符串）。 */
class AccountSnapshot {
  coins: number = 0;
  signDates: string[] = [];
  flows: WalletFlow[] = [];
  vipPlanId: string = '';
  vipExpire: string = '';
}

/**
 * 账号中心的本地沙箱存档：签到 7 天、金币流水、卡密兑换、VIP 沙箱开通、三榜样本。
 *
 * 说明：金币余额、会员状态优先用服务端接口（AccountApi/echomoney、uservipif）；
 * 本类只保存"接口没有的"本地数据（流水、连续签到、沙箱支付结果），
 * 便于在没接支付/卡密接口时先把完整流程跑通。
 */
export class AccountStore {
  static readonly PREF: string = 'wuyin';
  static readonly KEY: string = 'accountCenterSnapshot';
  /** 金币套餐（沙箱）：金币数 → 价格（元）。 */
  static readonly COIN_PACKS: number[] = [60, 300, 680, 1280, 3280];
  static readonly COIN_PRICES: number[] = [6, 30, 68, 128, 328];
  /** 签到奖励：第 1~6 天固定，第 7 天大奖。 */
  static readonly SIGN_REWARDS: number[] = [5, 8, 10, 12, 15, 20, 100];
  static coins: number = 0;
  static signDates: string[] = [];
  static flows: WalletFlow[] = [];
  static vipPlanId: string = '';
  static vipExpire: string = '';
  private static store?: preferences.Preferences;
  private static ready: boolean = false;

  static async init(context: common.UIAbilityContext): Promise<void> {
    if (AccountStore.ready) {
      return;
    }
    try {
      AccountStore.store = await preferences.getPreferences(context, AccountStore.PREF);
      const raw: string = String(await AccountStore.store.get(AccountStore.KEY, ''));
      if (raw.length > 0) {
        const snapshot: AccountSnapshot = JSON.parse(raw) as AccountSnapshot;
        AccountStore.coins = Number.isFinite(Number(snapshot.coins)) ? Number(snapshot.coins) : 0;
        AccountStore.signDates = Array.isArray(snapshot.signDates) ? snapshot.signDates : [];
        AccountStore.flows = Array.isArray(snapshot.flows) ? snapshot.flows : [];
        AccountStore.vipPlanId = typeof snapshot.vipPlanId === 'string' ? snapshot.vipPlanId : '';
        AccountStore.vipExpire = typeof snapshot.vipExpire === 'string' ? snapshot.vipExpire : '';
      }
      AccountStore.ready = true;
      Logger.info('ACCOUNT_STORE', '账号中心本地存档已恢复，金币=' + String(AccountStore.coins) +
        '，签到=' + String(AccountStore.signDates.length) + '，流水=' + String(AccountStore.flows.length));
    } catch (error) {
      Logger.error('ACCOUNT_STORE', '读取账号中心存档失败：' + String(error));
    }
  }

  static async save(): Promise<void> {
    const snapshot: AccountSnapshot = new AccountSnapshot();
    snapshot.coins = AccountStore.coins;
    snapshot.signDates = AccountStore.signDates;
    snapshot.flows = AccountStore.flows;
    snapshot.vipPlanId = AccountStore.vipPlanId;
    snapshot.vipExpire = AccountStore.vipExpire;
    try {
      const store: preferences.Preferences | undefined = AccountStore.store;
      if (store === undefined) {
        return;
      }
      await store.put(AccountStore.KEY, JSON.stringify(snapshot));
      await store.flush();
    } catch (error) {
      Logger.error('ACCOUNT_STORE', '保存账号中心存档失败：' + String(error));
    }
  }

  static today(): string {
    const date: Date = new Date();
    const month: string = date.getMonth() + 1 < 10 ? '0' + String(date.getMonth() + 1) : String(date.getMonth() + 1);
    const day: string = date.getDate() < 10 ? '0' + String(date.getDate()) : String(date.getDate());
    return date.getFullYear() + '-' + month + '-' + day;
  }

  static signedToday(): boolean {
    return AccountStore.signDates.includes(AccountStore.today());
  }

  /** 连续签到天数（今天未签则统计到昨天的连续天数）。 */
  static streak(): number {
    let count: number = 0;
    const cursor: Date = new Date();
    for (let index: number = 0; index < 60; index++) {
      const key: string = AccountStore.format(cursor);
      if (AccountStore.signDates.includes(key)) {
        count++;
        cursor.setDate(cursor.getDate() - 1);
        continue;
      }
      if (index === 0) {
        cursor.setDate(cursor.getDate() - 1);
        continue;
      }
      break;
    }
    return count;
  }

  private static format(date: Date): string {
    const month: string = date.getMonth() + 1 < 10 ? '0' + String(date.getMonth() + 1) : String(date.getMonth() + 1);
    const day: string = date.getDate() < 10 ? '0' + String(date.getDate()) : String(date.getDate());
    return date.getFullYear() + '-' + month + '-' + day;
  }

  /** 今天能领第几天（1~7 循环）与对应奖励。 */
  static signDay(): number {
    const next: number = AccountStore.streak() + 1;
    return ((next - 1) % 7) + 1;
  }

  static signReward(day: number): number {
    const index: number = Math.max(0, Math.min(AccountStore.SIGN_REWARDS.length - 1, day - 1));
    return AccountStore.SIGN_REWARDS[index];
  }

  /** 本地签到：记日期、加金币、写流水；返回本次是第几天、奖励多少。 */
  static async sign(): Promise<number> {
    const day: number = AccountStore.signDay();
    const reward: number = AccountStore.signReward(day);
    if (!AccountStore.signedToday()) {
      AccountStore.signDates = AccountStore.signDates.concat([AccountStore.today()]).slice(-90);
      AccountStore.coins += reward;
      AccountStore.addFlow('每日签到 · 第 ' + String(day) + ' 天', reward, reward >= 100 ? '第 7 天大奖' : '签到奖励');
      await AccountStore.save();
    }
    return reward;
  }

  static addFlow(title: string, amount: number, note: string): void {
    const flow: WalletFlow = new WalletFlow();
    const date: Date = new Date();
    const hh: string = date.getHours() < 10 ? '0' + String(date.getHours()) : String(date.getHours());
    const mm: string = date.getMinutes() < 10 ? '0' + String(date.getMinutes()) : String(date.getMinutes());
    flow.time = AccountStore.format(date) + ' ' + hh + ':' + mm;
    flow.title = title;
    flow.amount = amount;
    flow.note = note;
    AccountStore.flows = [flow].concat(AccountStore.flows).slice(0, 100);
  }

  /** 卡密兑换（沙箱）：格式 WY-XXXX-XXXX，按校验位算金币，真实卡密需接后端接口。 */
  static async redeem(code: string): Promise<number> {
    const normalized: string = code.trim().toUpperCase().replace(/\s+/g, '');
    if (!/^WY-[A-Z0-9]{4}-[A-Z0-9]{4}$/.test(normalized)) {
      throw new Error('卡密格式应为 WY-XXXX-XXXX');
    }
    let seed: number = 0;
    for (let index: number = 0; index < normalized.length; index++) {
      seed = (Math.imul(31, seed) + normalized.charCodeAt(index)) | 0;
    }
    const coins: number = 100 + Math.abs(seed) % 9 * 100;
    AccountStore.coins += coins;
    AccountStore.addFlow('卡密兑换', coins, normalized);
    await AccountStore.save();
    return coins;
  }

  static plans(): VipPlan[] {
    const list: VipPlan[] = [];
    list.push(AccountStore.plan('month', '月卡 VIP', 30, 12, '30 天 · 全站免广告 + 高清线路'));
    list.push(AccountStore.plan('quarter', '季卡 VIP', 90, 32, '90 天 · 含月卡权益 + 专属弹幕色'));
    list.push(AccountStore.plan('year', '年卡 VIP', 365, 108, '365 天 · 含季卡权益 + 年度徽章'));
    list.push(AccountStore.plan('forever', '永久 VIP', 36500, 298, '永久有效 · 全部权益 + 无音殿堂头衔'));
    return list;
  }

  private static plan(id: string, name: string, days: number, price: number, desc: string): VipPlan {
    const plan: VipPlan = new VipPlan();
    plan.id = id;
    plan.name = name;
    plan.days = days;
    plan.price = price;
    plan.desc = desc;
    return plan;
  }

  /** 沙箱支付：扣本地金币（1 元 = 10 金币折算），写流水并记录会员到期时间。 */
  static async buyVip(plan: VipPlan): Promise<string> {
    const cost: number = plan.price * 10;
    if (AccountStore.coins < cost) {
      throw new Error('金币不足，需 ' + String(cost) + ' 金币（可先充值或兑换卡密）');
    }
    AccountStore.coins -= cost;
    AccountStore.vipPlanId = plan.id;
    const base: Date = AccountStore.vipExpire.length > 0 ? new Date(AccountStore.vipExpire) : new Date();
    const start: Date = Number.isFinite(base.getTime()) && base.getTime() > Date.now() ? base : new Date();
    start.setDate(start.getDate() + plan.days);
    AccountStore.vipExpire = AccountStore.format(start);
    AccountStore.addFlow('开通 ' + plan.name, -cost, '沙箱支付');
    await AccountStore.save();
    return AccountStore.vipExpire;
  }

  /** 三榜（本地演示口径）：等级榜看 exp、金币榜看金币、帖子榜看帖子数。 */
  static ranks(kind: string, selfName: string, selfPraise: number, selfFans: number): RankRow[] {
    const rows: RankRow[] = [];
    rows.push(AccountStore.rankRow(selfName || '我', kind, selfPraise, selfFans));
    const samples: string[] = ['银幕旅人', '剪辑师小北', '放映员阿岚', '影评人老K', '片单收藏家'];
    for (let index: number = 0; index < samples.length; index++) {
      const name: string = samples[index];
      let seed: number = 0;
      for (let j: number = 0; j < name.length; j++) {
        seed = (Math.imul(31, seed) + name.charCodeAt(j)) | 0;
      }
      const base: number = Math.abs(seed);
      rows.push(AccountStore.rankRow(name, kind, 120 + base % 8000, 3 + base % 60));
    }
    rows.sort((first: RankRow, second: RankRow) => second.value - first.value);
    return rows;
  }

  private static rankRow(name: string, kind: string, praise: number, fans: number): RankRow {
    const row: RankRow = new RankRow();
    row.name = name;
    if (kind === 'money') {
      row.value = AccountStore.coins;
      row.extra = '金币';
    } else if (kind === 'praise') {
      row.value = praise;
      row.extra = '获赞';
    } else {
      row.value = fans;
      row.extra = '粉丝';
    }
    return row;
  }

  /**
   * 三榜（真实+本地混合口径）：
   * - 等级榜：自己用真实 exp 换算，好友用其 grade（账号等级）解析；
   * - 金币榜 / 帖子榜：自己用真实值，好友按等级估算（服务端没有开放他人金币/帖子接口）。
   */
  static ranksWithFriends(kind: string, selfName: string, selfPraise: number, selfFans: number,
    friendNames: string[], friendGrades: string[]): RankRow[] {
    const rows: RankRow[] = [];
    rows.push(AccountStore.rankRow(selfName || '我', kind, selfPraise, selfFans));
    for (let index: number = 0; index < friendNames.length; index++) {
      const name: string = friendNames[index];
      const gradeText: string = index < friendGrades.length ? friendGrades[index] : '';
      let level: number = 1;
      for (let cursor: number = 0; cursor < gradeText.length; cursor++) {
        const char: string = gradeText.charAt(cursor);
        if (char >= '0' && char <= '9') {
          let value: number = 0;
          while (cursor < gradeText.length && gradeText.charAt(cursor) >= '0' && gradeText.charAt(cursor) <= '9') {
            value = value * 10 + (gradeText.charCodeAt(cursor) - 48);
            cursor++;
          }
          level = Math.max(1, Math.min(100, value));
          break;
        }
      }
      const praise: number = level * 3;
      const fans: number = level * 2;
      rows.push(AccountStore.rankRow(name, kind, praise, fans));
    }
    rows.sort((first: RankRow, second: RankRow) => second.value - first.value);
    return rows;
  }
}
