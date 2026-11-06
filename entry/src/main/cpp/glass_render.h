/*
 * glass_render.h
 *
 * Core rendering engine for the liquid glass effect.
 * Manages EGL context, shader program, background texture,
 * and the render loop.
 *
 * OPTIMIZATIONS:
 * - Atomic<bool> for m_running/m_initialized (thread safety)
 * - m_initMutex for serialized Initialize() (double-check locking)
 * - Fixed-size ripple pool (no heap allocation)
 * - Dirty-flag uniform tracking (skip redundant glUniform calls)
 * - VAO for vertex attribute state caching
 * - Frame pacing condition variable for adaptive sleep
 */

#ifndef GLASS_RENDER_H
#define GLASS_RENDER_H

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES3/gl31.h>
#include <native_window/external_window.h>
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <string>
#include <mutex>
#include <thread>
#include <atomic>
#include <condition_variable>
#include <algorithm>

class EglManager;

class GlassRender {
public:
    GlassRender(const std::string& id);
    ~GlassRender();

    // Initialize rendering (EGL + shaders + textures)
    bool Initialize(NativeWindow* window);

    // Check if renderer has been initialized
    bool IsInitialized() const { return m_initialized.load(); }

    // Cleanup resources
    void Destroy();

    // Start the render loop in a background thread
    void StartRenderLoop();

    // Stop the render loop
    void StopRenderLoop();

    // Update renderer parameters
    void SetParams(float opacity, float blur, float refraction, float waveSpeed);
  // 主题色调：深色模式压暗玻璃薄雾，避免一片发白。
  void SetTint(float r, float g, float b);
    void SetTouchPosition(float x, float y);
    void TriggerRipple(float x, float y, float force);

    // Get renderer ID
    const std::string& GetId() const { return m_id; }

private:
    // Uniform location indices (must match glGetUniformLocation order)
    enum UniformIndex {
        UNI_BACKGROUND_TEX = 0,
        UNI_TIME,
        UNI_TOUCH_POS,
        UNI_OPACITY,
        UNI_BLUR,
        UNI_REFRACTION,
        UNI_WAVE_SPEED,
    UNI_TINT,
        UNI_RIPPLE_0,
        UNI_RIPPLE_1,
        UNI_RIPPLE_2,
        UNI_RIPPLE_3,
        UNI_RIPPLE_4,
        UNI_RIPPLE_5,
        UNI_RIPPLE_6,
        UNI_RIPPLE_7,
        UNI_RIPPLE_8,
        UNI_RIPPLE_9,
        UNI_RIPPLE_10,
        UNI_RIPPLE_11,
        UNI_RIPPLE_12,
        UNI_RIPPLE_13,
        UNI_RIPPLE_14,
        UNI_RIPPLE_15,
        UNI_COUNT
    };

    // Internal initialization steps
    bool InitShaders();
    bool InitBackgroundTexture();

    // Render frame (called from render thread)
    void RenderFrame();

    // Update ripple physics
    void UpdateRipples(float deltaTime);

    // ---- Constants ----
    static constexpr float TARGET_FRAME_TIME = 1.0f / 60.0f;  // ~16.667ms
    static constexpr float MAX_PHYSICS_DELTA = 0.1f;           // prevent spiral of death
    static constexpr float MAX_DISPLAY_DELTA = 1.0f / 180.0f;  // ~2 frames at 60fps
    static constexpr size_t RIPPLE_POOL_SIZE = 16;
static constexpr int MAX_RIPPLES = 16;

    // ---- Ripple fixed pool ----
    struct Ripple {
        float x, y;
        float force;
        float radius;
        float life;
        bool active;
    };

    // ---- Member variables ----

    // Renderer ID
    std::string m_id;

    // EGL manager
    EglManager* m_eglManager;

    // OpenGL resources
    GLuint m_program;
    GLuint m_vertexBuffer;
    GLuint m_backgroundTexture;
    GLuint m_vao;  // Vertex Array Object (caches attribute state)
    GLint m_uniformLocs[UNI_COUNT]; // Cached uniform locations

    // Shader parameters with dirty flags
    struct {
        float opacity;
        float blur;
        float refraction;
        float waveSpeed;
    float tintR = 0.92f;
    float tintG = 0.93f;
    float tintB = 0.95f;
    bool tintDirty = true;
        float time;
        float touchX;
        float touchY;
        bool touchActive;
        bool paramsDirty;      // opacity/blur/refraction/waveSpeed changed
        bool touchDirty;       // touchX/touchY changed
        bool resolutionDirty;  // width/height changed
    } m_params;

    // Ripple system (fixed pool, no heap allocation)
    Ripple m_ripplePool[RIPPLE_POOL_SIZE];
    size_t m_rippleHead;       // next write index (ring buffer)
    size_t m_rippleCount;      // active ripple count
    mutable std::mutex m_rippleMutex;

    // Render loop
    std::atomic<bool> m_running;
    std::atomic<bool> m_initialized;
    std::mutex m_initMutex;          // Serializes concurrent Initialize() calls
    std::thread m_renderThread;
    std::mutex m_renderMutex;
    std::condition_variable m_framePacingCond; // Adaptive sleep wake-up

    // Background dimensions
    int m_width;
    int m_height;
};

#endif // GLASS_RENDER_H
