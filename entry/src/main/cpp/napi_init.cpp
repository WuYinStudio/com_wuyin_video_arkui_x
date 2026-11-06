/*
 * napi_init.cpp
 *
 * NAPI module initialization for the liquid glass renderer.
 * Uses HarmonyOS NAPI constructor pattern for module registration.
 * Exports functions to ArkTS layer.
 */

#include "glass_render.h"
#include <hilog/log.h>
#include <string>
#include <unordered_map>
#include <mutex>
#include <napi/native_api.h>
#include <native_window/external_window.h>
#include <ace/xcomponent/native_interface_xcomponent.h>

#undef LOG_DOMAIN
#define LOG_DOMAIN 0x3200
#undef LOG_TAG
#define LOG_TAG "GlassNAPI"

// ---- XComponent Surface 回调：新版 NDK 不再提供 GetNativeWindow ----
static NativeWindow* g_surfaceWindow = nullptr;
static OH_NativeXComponent* g_nativeComponent = nullptr;

// 提前声明：Surface 就绪后要把已经注册但没初始化的渲染器补起来
static void StartPendingRenderers();

static void OnSurfaceCreatedCB(OH_NativeXComponent* component, void* window)
{
    g_nativeComponent = component;
    g_surfaceWindow = reinterpret_cast<NativeWindow*>(window);
    OH_LOG_INFO(LOG_APP, "OnSurfaceCreated: window=%{public}p", window);
    // onLoad 可能早于 Surface 创建，这里补一次初始化。
    StartPendingRenderers();
}

static void OnSurfaceChangedCB(OH_NativeXComponent* component, void* window)
{
    g_surfaceWindow = reinterpret_cast<NativeWindow*>(window);
    OH_LOG_INFO(LOG_APP, "OnSurfaceChanged: window=%{public}p", window);
}

static void OnSurfaceDestroyedCB(OH_NativeXComponent* component, void* window)
{
    g_surfaceWindow = nullptr;
    OH_LOG_INFO(LOG_APP, "OnSurfaceDestroyed");
}

static OH_NativeXComponent_Callback g_surfaceCallback = {
    .OnSurfaceCreated = OnSurfaceCreatedCB,
    .OnSurfaceChanged = OnSurfaceChangedCB,
    .OnSurfaceDestroyed = OnSurfaceDestroyedCB,
    .DispatchTouchEvent = nullptr,
};

// ---- Global renderer registry ----

static std::unordered_map<std::string, GlassRender*> g_renderers;
static std::mutex g_renderersMutex;

// ---- Helper: get/add/remove renderer by ID ----

static GlassRender* GetRenderer(const std::string& id)
{
    std::lock_guard<std::mutex> lock(g_renderersMutex);
    auto it = g_renderers.find(id);
    if (it != g_renderers.end()) {
        return it->second;
    }
    return nullptr;
}

static void AddRenderer(const std::string& id, GlassRender* renderer)
{
    std::lock_guard<std::mutex> lock(g_renderersMutex);
    g_renderers[id] = renderer;
}

static void RemoveRenderer(const std::string& id)
{
    std::lock_guard<std::mutex> lock(g_renderersMutex);
    g_renderers.erase(id);
}

// ---- NAPI Method Implementations ----

static napi_value RegisterGlass(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc < 1) {
        napi_throw_error(env, nullptr, "registerGlass requires an id string argument");
        return nullptr;
    }

    char idBuf[256] = {0};
    size_t idLen = 0;
    napi_get_value_string_utf8(env, argv[0], idBuf, sizeof(idBuf), &idLen);
    std::string id(idBuf, idLen);

    OH_LOG_INFO(LOG_APP, "registerGlass: id=%{public}s", id.c_str());

    GlassRender* renderer = new (std::nothrow) GlassRender(id);
    if (!renderer) {
        napi_throw_error(env, nullptr, "Failed to allocate GlassRender");
        return nullptr;
    }

    AddRenderer(id, renderer);

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value UnregisterGlass(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc < 1) {
        napi_throw_error(env, nullptr, "unregisterGlass requires an id string argument");
        return nullptr;
    }

    char idBuf[256] = {0};
    size_t idLen = 0;
    napi_get_value_string_utf8(env, argv[0], idBuf, sizeof(idBuf), &idLen);
    std::string id(idBuf, idLen);

    OH_LOG_INFO(LOG_APP, "unregisterGlass: id=%{public}s", id.c_str());

    GlassRender* renderer = GetRenderer(id);
    if (renderer) {
        renderer->StopRenderLoop();
        renderer->Destroy();
        RemoveRenderer(id);
        delete renderer;
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value SetParams(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value argv[5];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc < 5) {
        napi_throw_error(env, nullptr, "setParams requires 5 arguments: id, opacity, blur, refraction, waveSpeed");
        return nullptr;
    }

    char idBuf[256] = {0};
    size_t idLen = 0;
    napi_get_value_string_utf8(env, argv[0], idBuf, sizeof(idBuf), &idLen);
    std::string id(idBuf, idLen);

    double opacity = 0.0, blur = 0.0, refraction = 0.0, waveSpeed = 0.0;
    napi_get_value_double(env, argv[1], &opacity);
    napi_get_value_double(env, argv[2], &blur);
    napi_get_value_double(env, argv[3], &refraction);
    napi_get_value_double(env, argv[4], &waveSpeed);

    GlassRender* renderer = GetRenderer(id);
    if (renderer) {
        renderer->SetParams(
            (float)opacity,
            (float)blur,
            (float)refraction,
            (float)waveSpeed
        );
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value StartRender(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc < 1) {
        napi_throw_error(env, nullptr, "startRender requires an id string argument");
        return nullptr;
    }

    char idBuf[256] = {0};
    size_t idLen = 0;
    napi_get_value_string_utf8(env, argv[0], idBuf, sizeof(idBuf), &idLen);
    std::string id(idBuf, idLen);

    GlassRender* renderer = GetRenderer(id);
    if (!renderer) {
        OH_LOG_WARN(LOG_APP, "startRender: renderer not found for id=%{public}s", id.c_str());
        napi_value result;
        napi_get_undefined(env, &result);
        return result;
    }

    // Initialize renderer if not yet done
    if (!renderer->IsInitialized()) {
        if (!g_surfaceWindow) {
            OH_LOG_WARN(LOG_APP, "startRender: surface not ready for id=%{public}s", id.c_str());
            napi_value result;
            napi_get_undefined(env, &result);
            return result;
        }

        if (!renderer->Initialize(g_surfaceWindow)) {
            OH_LOG_ERROR(LOG_APP, "startRender: Initialize failed for id=%{public}s", id.c_str());
            napi_throw_error(env, nullptr, "Renderer initialization failed");
            return nullptr;
        }
    }

    renderer->StartRenderLoop();

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value StopRender(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc < 1) {
        napi_throw_error(env, nullptr, "stopRender requires an id string argument");
        return nullptr;
    }

    char idBuf[256] = {0};
    size_t idLen = 0;
    napi_get_value_string_utf8(env, argv[0], idBuf, sizeof(idBuf), &idLen);
    std::string id(idBuf, idLen);

    GlassRender* renderer = GetRenderer(id);
    if (renderer) {
        renderer->StopRenderLoop();
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// Surface 就绪后初始化所有已注册但尚未初始化的渲染器。
static void StartPendingRenderers()
{
    if (!g_surfaceWindow) { return; }
    std::lock_guard<std::mutex> lock(g_renderersMutex);
    for (auto& entry : g_renderers) {
        GlassRender* renderer = entry.second;
        if (!renderer) { continue; }
        if (!renderer->IsInitialized()) {
            if (!renderer->Initialize(g_surfaceWindow)) {
                OH_LOG_ERROR(LOG_APP, "auto init failed for id=%{public}s", entry.first.c_str());
                continue;
            }
            OH_LOG_INFO(LOG_APP, "auto init ok for id=%{public}s", entry.first.c_str());
        }
        renderer->StartRenderLoop();
    }
}

static napi_value SetTint(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 4) {
        napi_throw_error(env, nullptr, "setTint requires 4 arguments: id, r, g, b");
        return nullptr;
    }
    char idBuf[256] = {0};
    size_t idLen = 0;
    napi_get_value_string_utf8(env, argv[0], idBuf, sizeof(idBuf), &idLen);
    std::string id(idBuf, idLen);
    double r = 0.92, g = 0.93, b = 0.95;
    napi_get_value_double(env, argv[1], &r);
    napi_get_value_double(env, argv[2], &g);
    napi_get_value_double(env, argv[3], &b);
    GlassRender* renderer = GetRenderer(id);
    if (renderer) {
        renderer->SetTint(static_cast<float>(r), static_cast<float>(g), static_cast<float>(b));
    }
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value SetTouchPosition(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc < 3) {
        napi_throw_error(env, nullptr, "setTouchPosition requires 3 arguments: id, x, y");
        return nullptr;
    }

    char idBuf[256] = {0};
    size_t idLen = 0;
    napi_get_value_string_utf8(env, argv[0], idBuf, sizeof(idBuf), &idLen);
    std::string id(idBuf, idLen);

    double x = 0.0, y = 0.0;
    napi_get_value_double(env, argv[1], &x);
    napi_get_value_double(env, argv[2], &y);

    GlassRender* renderer = GetRenderer(id);
    if (renderer) {
        renderer->SetTouchPosition((float)x, (float)y);
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value TriggerRipple(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc < 4) {
        napi_throw_error(env, nullptr, "triggerRipple requires 4 arguments: id, x, y, force");
        return nullptr;
    }

    char idBuf[256] = {0};
    size_t idLen = 0;
    napi_get_value_string_utf8(env, argv[0], idBuf, sizeof(idBuf), &idLen);
    std::string id(idBuf, idLen);

    double x = 0.0, y = 0.0, force = 0.0;
    napi_get_value_double(env, argv[1], &x);
    napi_get_value_double(env, argv[2], &y);
    napi_get_value_double(env, argv[3], &force);

    GlassRender* renderer = GetRenderer(id);
    if (renderer) {
        renderer->TriggerRipple((float)x, (float)y, (float)force);
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// ---- NAPI Property Descriptors ----

static napi_property_descriptor g_properties[] = {
    { "registerGlass", nullptr, RegisterGlass, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "unregisterGlass", nullptr, UnregisterGlass, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "setParams", nullptr, SetParams, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "startRender", nullptr, StartRender, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "stopRender", nullptr, StopRender, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "setTouchPosition", nullptr, SetTouchPosition, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "setTint", nullptr, SetTint, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "triggerRipple", nullptr, TriggerRipple, nullptr, nullptr, nullptr, napi_default, nullptr },
};

// ---- NAPI Module Initialization (HarmonyOS constructor pattern) ----

static napi_value Init(napi_env env, napi_value exports)
{
    napi_define_properties(env, exports,
                           sizeof(g_properties) / sizeof(g_properties[0]),
                           g_properties);

    // 绑定当前 XComponent 的原生实例，注册 Surface 生命周期回调
    napi_value exportInstance = nullptr;
    if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &exportInstance) == napi_ok) {
        napi_unwrap(env, exportInstance, reinterpret_cast<void**>(&g_nativeComponent));
        if (g_nativeComponent) {
            OH_NativeXComponent_RegisterCallback(g_nativeComponent, &g_surfaceCallback);
            OH_LOG_INFO(LOG_APP, "XComponent callback registered");
        }
    }
    return exports;
}

static napi_module g_nativeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "libglass",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterGlassModule()
{
    napi_module_register(&g_nativeModule);
}
