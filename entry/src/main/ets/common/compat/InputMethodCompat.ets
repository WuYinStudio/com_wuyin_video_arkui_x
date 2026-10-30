/**
 * IMEKit 跨平台适配层：仅用于主动收起输入法。
 * Android/iOS 上通过 clearFocus 即可收起软键盘，stopInputSession 为空实现。
 */
export class InputMethodController {
  async stopInputSession(): Promise<void> {
  }
}

export class InputMethod {
  private controller: InputMethodController = new InputMethodController();

  getController(): InputMethodController {
    return this.controller;
  }
}

export const inputMethod: InputMethod = new InputMethod();
