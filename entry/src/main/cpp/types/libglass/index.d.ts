/**
 * TypeScript interface declarations for the native glass renderer module.
 * These declarations provide type safety when calling native functions
 * from ArkTS/ETS code.
 */

export interface GlassParams {
  opacity: number;
  blur: number;
  refraction: number;
  waveSpeed: number;
}

/**
 * Register a glass renderer instance with the given XComponent ID.
 */
export const registerGlass: (id: string) => void;

/**
 * Unregister and destroy a glass renderer instance.
 */
export const unregisterGlass: (id: string) => void;

/**
 * Update rendering parameters.
 */
export const setParams: (
  id: string,
  opacity: number,
  blur: number,
  refraction: number,
  waveSpeed: number
) => void;

/**
 * Start the render loop for the given renderer.
 */
export const startRender: (id: string) => void;

/**
 * Stop the render loop for the given renderer.
 */
export const stopRender: (id: string) => void;

/**
 * Set the current touch position (normalized coordinates 0-1).
 */
export const setTouchPosition: (id: string, x: number, y: number) => void;

/**
 * Trigger a ripple effect at the given position.
 */
export const triggerRipple: (
  id: string,
  x: number,
  y: number,
  force: number
) => void;

export const setTint: (id: string, r: number, g: number, b: number) => void;
