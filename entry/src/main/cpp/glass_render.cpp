/*
 * glass_render.cpp
 *
 * Core rendering engine implementation for the liquid glass effect.
 *
 * OPTIMIZATIONS:
 * - Fixed-size ripple pool (ring buffer, no heap allocation)
 * - Dirty-flag uniform tracking (skip redundant glUniform calls)
 * - VAO for vertex attribute state caching
 * - Frame pacing with condition variable (adaptive sleep)
 * - Separate physics/display delta caps
 * - CPU-side skip when opacity < 0.001
 * - Atomic<bool> for m_running/m_initialized
 * - m_initMutex serialization for concurrent Initialize()
 */

#include "glass_render.h"
#include "glass_shader.h"
#include "egl_manager.h"
#include <hilog/log.h>
#include <thread>
#include <chrono>
#include <GLES3/gl3.h>
#include <cstring>
#include <cmath>
#include <numeric>

#undef LOG_DOMAIN
#define LOG_DOMAIN 0x3200
#undef LOG_TAG
#define LOG_TAG "GlassRender"

// ---- Construction / Destruction ----

GlassRender::GlassRender(const std::string& id)
    : m_id(id)
    , m_eglManager(nullptr)
    , m_program(0)
    , m_vertexBuffer(0)
    , m_backgroundTexture(0)
    , m_vao(0)
    , m_params{0.82f, 8.0f, 0.04f, 1.2f, 0.0f, -1.0f, -1.0f, false, true, true, true}
    , m_rippleHead(0)
    , m_rippleCount(0)
    , m_running(false)
    , m_initialized(false)
    , m_width(0)
    , m_height(0)
{
    // Zero-initialize the ripple pool
    memset(m_ripplePool, 0, sizeof(m_ripplePool));
    memset(m_uniformLocs, -1, sizeof(m_uniformLocs));
}

GlassRender::~GlassRender()
{
    Destroy();
}

// ---- Public lifecycle ----

bool GlassRender::Initialize(NativeWindow* nativeWindow)
{
    // Fast path: already initialized (atomic read, no lock)
    if (m_initialized.load()) {
        OH_LOG_WARN(LOG_APP, "GlassRender [%{public}s] already initialized", m_id.c_str());
        return true;
    }

    // Slow path: serialize concurrent Initialize() calls to prevent
    // double EGL/shader/resource allocation from racing threads.
    std::lock_guard<std::mutex> initLock(m_initMutex);

    // Re-check after acquiring lock (another thread may have initialized)
    if (m_initialized.load()) {
        OH_LOG_WARN(LOG_APP, "GlassRender [%{public}s] already initialized (racing thread)", m_id.c_str());
        return true;
    }

    // 1. NativeWindow 由 napi 层的 SurfaceCreated 回调传入
    if (!nativeWindow) {
        OH_LOG_ERROR(LOG_APP, "GlassRender [%{public}s]: NativeWindow is null", m_id.c_str());
        return false;
    }

    // 2. Create EGL manager and initialize with NativeWindow
    m_eglManager = new (std::nothrow) EglManager();
    if (!m_eglManager) {
        OH_LOG_ERROR(LOG_APP, "GlassRender [%{public}s]: Failed to allocate EglManager", m_id.c_str());
        return false;
    }

    if (!m_eglManager->Initialize(nativeWindow)) {
        OH_LOG_ERROR(LOG_APP, "GlassRender [%{public}s]: EGL initialization failed", m_id.c_str());
        Destroy();
        return false;
    }

    m_width = m_eglManager->GetWidth();
    m_height = m_eglManager->GetHeight();

    // 3. Compile and link shaders
    if (!InitShaders()) {
        OH_LOG_ERROR(LOG_APP, "GlassRender [%{public}s]: Shader compilation failed", m_id.c_str());
        Destroy();
        return false;
    }

    // 4. Create background texture
    if (!InitBackgroundTexture()) {
        OH_LOG_ERROR(LOG_APP, "GlassRender [%{public}s]: Background texture creation failed", m_id.c_str());
        Destroy();
        return false;
    }

    // 5. Create and bind vertex buffer for full-screen quad
    glGenBuffers(1, &m_vertexBuffer);
    glBindBuffer(GL_ARRAY_BUFFER, m_vertexBuffer);
    const float vertices[] = {
        // position    // texcoord
        -1.0f, -1.0f,  0.0f, 0.0f,
         1.0f, -1.0f,  1.0f, 0.0f,
        -1.0f,  1.0f,  0.0f, 1.0f,
         1.0f,  1.0f,  1.0f, 1.0f,
    };
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);

    // 6. Create VAO to cache vertex attribute state (OPTIMIZATION: reduces per-frame GL calls)
    glGenVertexArrays(1, &m_vao);
    glBindVertexArray(m_vao);
    glBindBuffer(GL_ARRAY_BUFFER, m_vertexBuffer);
    glEnableVertexAttribArray(0); // aPosition
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)0);
    glEnableVertexAttribArray(1); // aTexCoord
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)(2 * sizeof(float)));
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glBindVertexArray(0);

    // 7. Cache uniform locations for fast access during render
    m_uniformLocs[UNI_BACKGROUND_TEX] = glGetUniformLocation(m_program, "uBackgroundTex");
    m_uniformLocs[UNI_TIME]          = glGetUniformLocation(m_program, "uTime");
    m_uniformLocs[UNI_TOUCH_POS]     = glGetUniformLocation(m_program, "uTouchPos");
    m_uniformLocs[UNI_OPACITY]       = glGetUniformLocation(m_program, "uOpacity");
    m_uniformLocs[UNI_BLUR]          = glGetUniformLocation(m_program, "uBlur");
    m_uniformLocs[UNI_REFRACTION]    = glGetUniformLocation(m_program, "uRefraction");
    m_uniformLocs[UNI_WAVE_SPEED]    = glGetUniformLocation(m_program, "uWaveSpeed");
    m_uniformLocs[UNI_TINT]          = glGetUniformLocation(m_program, "uTint");
    for (int i = 0; i < MAX_RIPPLES; i++) {
        char name[32];
        snprintf(name, sizeof(name), "uRipples[%d]", i);
        m_uniformLocs[UNI_RIPPLE_0 + i] = glGetUniformLocation(m_program, name);
    }

    // 8. Reset ripple pool
    memset(m_ripplePool, 0, sizeof(m_ripplePool));
    m_rippleHead = 0;
    m_rippleCount = 0;

    // 9. Mark all params dirty for first frame upload
    m_params.paramsDirty = true;
    m_params.touchDirty = true;
    m_params.resolutionDirty = true;

    m_initialized.store(true);
    OH_LOG_INFO(LOG_APP, "GlassRender [%{public}s] initialized (%dx%d)",
                m_id.c_str(), m_width, m_height);
    return true;
}

void GlassRender::Destroy()
{
    // Stop render loop first
    StopRenderLoop();

    // Wake any sleeping frame pacing thread
    m_framePacingCond.notify_one();

    // Cleanup OpenGL resources
    if (m_vao != 0) {
        glDeleteVertexArrays(1, &m_vao);
        m_vao = 0;
    }
    if (m_backgroundTexture != 0) {
        glDeleteTextures(1, &m_backgroundTexture);
        m_backgroundTexture = 0;
    }
    if (m_vertexBuffer != 0) {
        glDeleteBuffers(1, &m_vertexBuffer);
        m_vertexBuffer = 0;
    }
    if (m_program != 0) {
        glDeleteProgram(m_program);
        m_program = 0;
    }
    memset(m_uniformLocs, -1, sizeof(m_uniformLocs));

    // Cleanup EGL manager
    if (m_eglManager) {
        m_eglManager->Destroy();
        delete m_eglManager;
        m_eglManager = nullptr;
    }

    // Clear ripple pool
    memset(m_ripplePool, 0, sizeof(m_ripplePool));
    m_rippleHead = 0;
    m_rippleCount = 0;

    m_running.store(false);
    m_initialized.store(false);
    m_width = 0;
    m_height = 0;
    OH_LOG_INFO(LOG_APP, "GlassRender [%{public}s] destroyed", m_id.c_str());
}

void GlassRender::StartRenderLoop()
{
    if (m_running.load()) {
        OH_LOG_WARN(LOG_APP, "GlassRender [%{public}s]: Render loop already running", m_id.c_str());
        return;
    }

    if (!m_initialized.load()) {
        OH_LOG_ERROR(LOG_APP, "GlassRender [%{public}s]: Cannot start render loop - not initialized", m_id.c_str());
        return;
    }

    m_running.store(true);
    m_renderThread = std::thread([this]() {
        OH_LOG_INFO(LOG_APP, "GlassRender [%{public}s]: Render thread started", m_id.c_str());

        auto lastFrameStart = std::chrono::high_resolution_clock::now();

        while (m_running.load()) {
            // Calculate delta time
            auto frameStart = std::chrono::high_resolution_clock::now();
            float delta = std::chrono::duration<float>(frameStart - lastFrameStart).count();
            lastFrameStart = frameStart;

            // Cap deltas to prevent spiral of death and visual pops
            float physicsDelta = std::min(delta, MAX_PHYSICS_DELTA);
            float displayDelta = std::min(delta, MAX_DISPLAY_DELTA);

            // Update ripple physics FIRST (acquires m_rippleMutex)
            // Consistent lock ordering: m_rippleMutex -> m_renderMutex
            UpdateRipples(physicsDelta);

            // Render frame (acquires m_renderMutex for EGL + param reads)
            {
                std::lock_guard<std::mutex> lock(m_renderMutex);
                if (m_eglManager && m_eglManager->IsInitialized()) {
                    if (!m_eglManager->MakeCurrent()) {
                        OH_LOG_ERROR(LOG_APP, "GlassRender [%{public}s]: Failed to make EGL current", m_id.c_str());
                        continue;
                    }

                    // CPU-side early-out: skip all GPU work when fully transparent
                    if (m_params.opacity < 0.001f) {
                        m_eglManager->SwapBuffers();
                        continue;
                    }

                    m_params.time += displayDelta;
                    RenderFrame();
                }
            }

            // Frame pacing: sleep for the remainder of the target frame budget
            auto frameEnd = std::chrono::high_resolution_clock::now();
            float elapsed = std::chrono::duration<float>(frameEnd - frameStart).count();
            float sleepDuration = TARGET_FRAME_TIME - elapsed;

            if (sleepDuration > 0.0f) {
                std::unique_lock<std::mutex> pacingLock(m_renderMutex);
                m_framePacingCond.wait_for(pacingLock, std::chrono::duration<float>(sleepDuration));
            }
        }

        OH_LOG_INFO(LOG_APP, "GlassRender [%{public}s]: Render thread stopped", m_id.c_str());
    });

    OH_LOG_INFO(LOG_APP, "GlassRender [%{public}s]: Render loop started", m_id.c_str());
}

void GlassRender::StopRenderLoop()
{
    if (!m_running.load()) {
        return;
    }

    m_running.store(false);

    // Wake the frame pacing sleep immediately
    m_framePacingCond.notify_one();

    if (m_renderThread.joinable()) {
        m_renderThread.join();
    }

    OH_LOG_INFO(LOG_APP, "GlassRender [%{public}s]: Render loop stopped", m_id.c_str());
}

// ---- Parameter updates ----

void GlassRender::SetParams(float opacity, float blur, float refraction, float waveSpeed)
{
    std::lock_guard<std::mutex> lock(m_renderMutex);
    if (m_params.opacity != opacity || m_params.blur != blur ||
        m_params.refraction != refraction || m_params.waveSpeed != waveSpeed) {
        m_params.opacity = opacity;
        m_params.blur = blur;
        m_params.refraction = refraction;
        m_params.waveSpeed = waveSpeed;
        m_params.paramsDirty = true;
    }
}

void GlassRender::SetTint(float r, float g, float b)
{
    std::lock_guard<std::mutex> lock(m_renderMutex);
    if (m_params.tintR != r || m_params.tintG != g || m_params.tintB != b) {
        m_params.tintR = r;
        m_params.tintG = g;
        m_params.tintB = b;
        m_params.tintDirty = true;
    }
}

void GlassRender::SetTouchPosition(float x, float y)
{
    std::lock_guard<std::mutex> lock(m_renderMutex);
    if (m_params.touchX != x || m_params.touchY != y) {
        m_params.touchX = x;
        m_params.touchY = y;
        m_params.touchActive = (x >= 0.0f && y >= 0.0f);
        m_params.touchDirty = true;
    }
}

void GlassRender::TriggerRipple(float x, float y, float force)
{
    std::lock_guard<std::mutex> lock(m_rippleMutex);

    // Write at head position (overwrites oldest if pool is full)
    Ripple& slot = m_ripplePool[m_rippleHead];
    slot.x = x;
    slot.y = y;
    slot.force = force;
    slot.radius = 0.02f;
    slot.life = 0.0f;
    slot.active = true;

    m_rippleHead = (m_rippleHead + 1) % RIPPLE_POOL_SIZE;
    if (m_rippleCount < RIPPLE_POOL_SIZE) {
        m_rippleCount++;
    }
}

// ---- Shader compilation ----

bool GlassRender::InitShaders()
{
    // Compile vertex shader
    GLuint vertexShader = glCreateShader(GL_VERTEX_SHADER);
    glShaderSource(vertexShader, 1, &VERTEX_SHADER_SOURCE, nullptr);
    glCompileShader(vertexShader);

    GLint vertexStatus = GL_FALSE;
    glGetShaderiv(vertexShader, GL_COMPILE_STATUS, &vertexStatus);
    if (vertexStatus != GL_TRUE) {
        GLint logLen = 0;
        glGetShaderiv(vertexShader, GL_INFO_LOG_LENGTH, &logLen);
        if (logLen > 1) {
            char* log = new (std::nothrow) char[logLen];
            if (log) {
                glGetShaderInfoLog(vertexShader, logLen, nullptr, log);
                OH_LOG_ERROR(LOG_APP, "Vertex shader compile error: %{public}s", log);
                delete[] log;
            }
        }
        glDeleteShader(vertexShader);
        return false;
    }

    // Compile fragment shader
    GLuint fragmentShader = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(fragmentShader, 1, &FRAGMENT_SHADER_SOURCE, nullptr);
    glCompileShader(fragmentShader);

    GLint fragmentStatus = GL_FALSE;
    glGetShaderiv(fragmentShader, GL_COMPILE_STATUS, &fragmentStatus);
    if (fragmentStatus != GL_TRUE) {
        GLint logLen = 0;
        glGetShaderiv(fragmentShader, GL_INFO_LOG_LENGTH, &logLen);
        if (logLen > 1) {
            char* log = new (std::nothrow) char[logLen];
            if (log) {
                glGetShaderInfoLog(fragmentShader, logLen, nullptr, log);
                OH_LOG_ERROR(LOG_APP, "Fragment shader compile error: %{public}s", log);
                delete[] log;
            }
        }
        glDeleteShader(fragmentShader);
        glDeleteShader(vertexShader);
        return false;
    }

    // Link program
    m_program = glCreateProgram();
    glAttachShader(m_program, vertexShader);
    glAttachShader(m_program, fragmentShader);
    glLinkProgram(m_program);

    GLint linkStatus = GL_FALSE;
    glGetProgramiv(m_program, GL_LINK_STATUS, &linkStatus);
    if (linkStatus != GL_TRUE) {
        GLint logLen = 0;
        glGetProgramiv(m_program, GL_INFO_LOG_LENGTH, &logLen);
        if (logLen > 1) {
            char* log = new (std::nothrow) char[logLen];
            if (log) {
                glGetProgramInfoLog(m_program, logLen, nullptr, log);
                OH_LOG_ERROR(LOG_APP, "Shader link error: %{public}s", log);
                delete[] log;
            }
        }
        glDeleteProgram(m_program);
        m_program = 0;
        glDeleteShader(fragmentShader);
        glDeleteShader(vertexShader);
        return false;
    }

    // Shader objects no longer needed after linking
    glDeleteShader(vertexShader);
    glDeleteShader(fragmentShader);

    OH_LOG_INFO(LOG_APP, "GlassRender [%{public}s]: Shaders compiled and linked", m_id.c_str());
    return true;
}

// ---- Background texture creation (128x128, no mipmaps) ----

bool GlassRender::InitBackgroundTexture()
{
    // OPTIMIZATION: 128x128 texture (was 256x256).
    // The shader applies UV distortion with max offset ~0.06.
    // At 128x128, one texel = 0.0078 in UV space.
    // The 15-texel distortion is well within GL_LINEAR interpolation quality.
    // No mipmaps needed (quad always fills viewport, no minification).
    const int texSize = 128;

    glGenTextures(1, &m_backgroundTexture);
    glBindTexture(GL_TEXTURE_2D, m_backgroundTexture);

    // Generate gradient pixel data
    std::vector<uint8_t> texData(texSize * texSize * 4);
    for (int y = 0; y < texSize; y++) {
        for (int x = 0; x < texSize; x++) {
            int idx = (y * texSize + x) * 4;
            float fx = (float)x / texSize;
            float fy = (float)y / texSize;

            // 中性近白渐变：作为玻璃自身的一层薄雾，不抢背景色
            texData[idx + 0] = (uint8_t)(232 + fy * 20);  // R
            texData[idx + 1] = (uint8_t)(234 + fy * 18);  // G
            texData[idx + 2] = (uint8_t)(238 + fx * 16);  // B
            texData[idx + 3] = 255;                        // A
        }
    }

    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, texSize, texSize, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, texData.data());

    // OPTIMIZATION: No mipmaps (GL_LINEAR only)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    // Check for GL errors
    GLenum err = glGetError();
    if (err != GL_NO_ERROR) {
        OH_LOG_ERROR(LOG_APP, "GlassRender [%{public}s]: glTexImage2D error 0x%{public}x", m_id.c_str(), err);
        return false;
    }

    OH_LOG_INFO(LOG_APP, "GlassRender [%{public}s]: Background texture created (%dx%d, no mipmaps)",
                m_id.c_str(), texSize, texSize);
    return true;
}

// ---- Per-frame rendering ----

void GlassRender::RenderFrame()
{
    if (!m_eglManager || !m_eglManager->IsInitialized() || m_program == 0) {
        return;
    }

    // Set viewport to match current surface dimensions
    glViewport(0, 0, m_width, m_height);

    // Clear with transparent background
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    // 关闭混合：着色器已输出预乘 alpha，直接写入缓冲区；
    // 若再开 GL_BLEND，alpha 会被乘两次，深色/浅色都会整体发暗。
    glDisable(GL_BLEND);

    glUseProgram(m_program);

    // Bind background texture to texture unit 0
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, m_backgroundTexture);
    if (m_uniformLocs[UNI_BACKGROUND_TEX] >= 0) {
        glUniform1i(m_uniformLocs[UNI_BACKGROUND_TEX], 0);
    }

    // Set time uniform (changes every frame)
    if (m_uniformLocs[UNI_TIME] >= 0) {
        glUniform1f(m_uniformLocs[UNI_TIME], m_params.time);
    }

    // Set touch position uniform (only when changed - dirty flag)
    if (m_params.touchDirty && m_uniformLocs[UNI_TOUCH_POS] >= 0) {
        glUniform2f(m_uniformLocs[UNI_TOUCH_POS], m_params.touchX, m_params.touchY);
        m_params.touchDirty = false;
    }

    // Set glass parameter uniforms (only when changed - dirty flag)
    if (m_params.paramsDirty) {
        if (m_uniformLocs[UNI_OPACITY] >= 0)
            glUniform1f(m_uniformLocs[UNI_OPACITY], m_params.opacity);
        if (m_uniformLocs[UNI_BLUR] >= 0)
            glUniform1f(m_uniformLocs[UNI_BLUR], m_params.blur);
        if (m_uniformLocs[UNI_REFRACTION] >= 0)
            glUniform1f(m_uniformLocs[UNI_REFRACTION], m_params.refraction);
        if (m_uniformLocs[UNI_WAVE_SPEED] >= 0)
            glUniform1f(m_uniformLocs[UNI_WAVE_SPEED], m_params.waveSpeed);
        m_params.paramsDirty = false;
    }
    if (m_params.tintDirty) {
        if (m_uniformLocs[UNI_TINT] >= 0)
            glUniform3f(m_uniformLocs[UNI_TINT], m_params.tintR, m_params.tintG, m_params.tintB);
        m_params.tintDirty = false;
    }

    // Set ripple data uniforms (fixed 16-iteration, sentinel skip)
    {
        std::lock_guard<std::mutex> lock(m_rippleMutex);
        int count = (int)m_rippleCount;
        // uRippleCount uniform removed - loop is always MAX_RIPPLES with sentinel skip

        // Compute start index for linear traversal of ring buffer
        size_t startIdx = 0;
        if (m_rippleCount > 0) {
            startIdx = (m_rippleHead >= m_rippleCount)
                ? m_rippleHead - m_rippleCount
                : RIPPLE_POOL_SIZE + m_rippleHead - m_rippleCount;
        }

        for (int i = 0; i < count && i < MAX_RIPPLES; i++) {
            size_t idx = (startIdx + i) % RIPPLE_POOL_SIZE;
            const Ripple& r = m_ripplePool[idx];
            if (m_uniformLocs[UNI_RIPPLE_0 + i] >= 0) {
                glUniform4f(m_uniformLocs[UNI_RIPPLE_0 + i],
                            r.x, r.y, r.radius, r.force);
            }
        }
    }

    // Bind VAO and draw (OPTIMIZATION: 2 GL calls instead of 7)
    glBindVertexArray(m_vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);

    // Present
    m_eglManager->SwapBuffers();
}

// ---- Ripple physics update (fixed pool) ----

void GlassRender::UpdateRipples(float deltaTime)
{
    std::lock_guard<std::mutex> lock(m_rippleMutex);

    if (m_rippleCount == 0) return;

    // Compute start index for linear traversal
    size_t startIdx = (m_rippleHead >= m_rippleCount)
        ? m_rippleHead - m_rippleCount
        : RIPPLE_POOL_SIZE + m_rippleHead - m_rippleCount;

    // Update all active ripples
    for (size_t i = 0; i < m_rippleCount; i++) {
        size_t idx = (startIdx + i) % RIPPLE_POOL_SIZE;
        Ripple& r = m_ripplePool[idx];

        r.radius += deltaTime * 0.8f;
        r.force *= (1.0f - deltaTime * 1.2f);
        r.life += deltaTime;

        if (r.force < 0.01f || r.life > 2.0f) {
            r.active = false;
        }
    }

    // Compact: remove inactive by shifting active to front
    size_t writeIdx = 0;
    for (size_t i = 0; i < m_rippleCount; i++) {
        size_t idx = (startIdx + i) % RIPPLE_POOL_SIZE;
        if (m_ripplePool[idx].active) {
            if (writeIdx != i) {
                size_t writeIdxMod = (startIdx + writeIdx) % RIPPLE_POOL_SIZE;
                m_ripplePool[writeIdxMod] = m_ripplePool[idx];
            }
            writeIdx++;
        }
    }
    m_rippleCount = writeIdx;
}
