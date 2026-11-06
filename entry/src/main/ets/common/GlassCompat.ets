/**
 * libglass.so 的跨平台空实现。
 *
 * HarmonyOS 使用原生 OpenGL ES 渲染液态玻璃；Android / iOS 不加载该 .so，
 * 由 UiWidgets 中的 ArkUI 渐变、backdropBlur 与描边完成降级。
 * 保留同名签名，避免业务层出现平台分支。
 */
export const registerGlass: (id: string) => void = (_id: string): void => {};
export const unregisterGlass: (id: string) => void = (_id: string): void => {};
export const setParams: (id: string, opacity: number, blur: number, refraction: number, waveSpeed: number) => void =
  (_id: string, _opacity: number, _blur: number, _refraction: number, _waveSpeed: number): void => {};
export const startRender: (id: string) => void = (_id: string): void => {};
export const stopRender: (id: string) => void = (_id: string): void => {};
export const setTouchPosition: (id: string, x: number, y: number) => void =
  (_id: string, _x: number, _y: number): void => {};
export const triggerRipple: (id: string, x: number, y: number, force: number) => void =
  (_id: string, _x: number, _y: number, _force: number): void => {};
export const setTint: (id: string, r: number, g: number, b: number) => void =
  (_id: string, _r: number, _g: number, _b: number): void => {};
