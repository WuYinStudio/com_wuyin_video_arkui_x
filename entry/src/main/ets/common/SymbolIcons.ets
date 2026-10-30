/**
 * 鸿蒙原生图标（SymbolGlyph 使用的 sys.symbol 资源）。
 *
 * 说明：`sys.symbol.*` 是系统内置符号，名字写错会在编译期报资源找不到。
 * 这里集中维护"语义 → 系统符号"的映射，页面只引用这里，方便一处替换。
 *
 * 其中 home/category/manage/settings/mine 以及 play/pause/forward 等已在工程中使用并验证；
 * message/forum/live 三个新入口使用 HarmonyOS 符号库中常见的聊天/文档/播放矩形符号，
 * 若某个 SDK 版本没有对应名字，只需要改本文件里的一行即可。
 */
export class SymbolIcons {
  // 底栏（未选中 / 选中）
  static home(selected: boolean): Resource {
    return selected ? $r('sys.symbol.house_fill') : $r('sys.symbol.house');
  }
  static message(selected: boolean): Resource {
    return selected ? $r('sys.symbol.message_fill') : $r('sys.symbol.message');
  }
  static forum(selected: boolean): Resource {
    return selected ? $r('sys.symbol.doc_text_fill') : $r('sys.symbol.doc_text');
  }
  static live(selected: boolean): Resource {
    return selected ? $r('sys.symbol.play_fill') : $r('sys.symbol.play_fill');
  }
  static category(selected: boolean): Resource {
    return selected ? $r('sys.symbol.square_fill_grid_2x2') : $r('sys.symbol.square_grid_2x2');
  }
  static manage(selected: boolean): Resource {
    return selected ? $r('sys.symbol.folder_fill') : $r('sys.symbol.folder');
  }
  static settings(selected: boolean): Resource {
    return selected ? $r('sys.symbol.gearshape_fill') : $r('sys.symbol.gearshape');
  }
  static mine(selected: boolean): Resource {
    return selected ? $r('sys.symbol.person_fill') : $r('sys.symbol.person');
  }

  /** 按底栏 key 取图标；未知 key 回退首页，保证底栏永远有图标。 */
  static tab(key: string, selected: boolean): Resource {
    if (key === 'message') { return SymbolIcons.message(selected); }
    if (key === 'forum') { return SymbolIcons.forum(selected); }
    if (key === 'live') { return SymbolIcons.live(selected); }
    if (key === 'category') { return SymbolIcons.category(selected); }
    if (key === 'manage') { return SymbolIcons.manage(selected); }
    if (key === 'settings') { return SymbolIcons.settings(selected); }
    if (key === 'mine') { return SymbolIcons.mine(selected); }
    return SymbolIcons.home(selected);
  }

  /** 通用动作图标（工程内已验证可用的名字）。 */
  static play(): Resource { return $r('sys.symbol.play_fill'); }
  static pause(): Resource { return $r('sys.symbol.pause_fill'); }
  static forward(): Resource { return $r('sys.symbol.forward_end_fill'); }
  static search(): Resource { return $r('sys.symbol.magnifyingglass'); }
  static close(): Resource { return $r('sys.symbol.xmark'); }
  static back(): Resource { return $r('sys.symbol.chevron_left_circle'); }
  static cast(): Resource { return $r('sys.symbol.wireless_projection'); }
  /** 文件 / 文档（本工程已验证可用的 doc_text 系列）。 */
  static file(): Resource { return $r('sys.symbol.doc_text'); }
  static fileFill(): Resource { return $r('sys.symbol.doc_text_fill'); }
  /** 文字消息 / 聊天。 */
  static chat(): Resource { return $r('sys.symbol.doc_text'); }

  // ---------------- 语义图标（按 HarmonyOS Symbol 命名规则选择） ----------------
  // 说明：以下名字沿用已通过编译的 doc_text 系列命名方式（下划线小写）；
  // 若某个名字在你 SDK 里不存在，编译会明确报 "Unknown resource name 'xxx'"，改对应一行即可。
  static image(): Resource { return $r('sys.symbol.camera'); }
  static music(): Resource { return $r('sys.symbol.play_fill'); }
  static video(): Resource { return $r('sys.symbol.video'); }
  static bell(): Resource { return $r('sys.symbol.bell'); }
  static wallet(): Resource { return $r('sys.symbol.creditcard'); }
  static calendar(): Resource { return $r('sys.symbol.calendar'); }
  static trophy(): Resource { return $r('sys.symbol.list_bullet'); }
  static list(): Resource { return $r('sys.symbol.list_bullet'); }
  static palette(): Resource { return $r('sys.symbol.paintpalette'); }
  static terminal(): Resource { return $r('sys.symbol.doc_text'); }
  static mail(): Resource { return $r('sys.symbol.envelope'); }
  static doc(): Resource { return $r('sys.symbol.doc_text'); }
}
