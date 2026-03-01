#include "ui.h"
#include <SDL3/SDL.h>
#include <SDL3/SDL_dialog.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include "imgui.h"
#include "backends/imgui_impl_sdl3.h"
#include "backends/imgui_impl_sdlrenderer3.h"
#include "backends/imgui_impl_vulkan.h"

typedef struct {
    App* app;
    VkDescriptorPool descriptor_pool;
    SDL_Mutex* file_mutex;
    char selected_file[1024];
    int has_selected_file;
    UIAction actions[64];
    int action_head;
    int action_tail;
    int action_count;
    PlaybackSnapshot snapshot;
    int has_snapshot;
    int show_debug_panel;
    int use_sdl_renderer;
    int initialized;
} UIRuntime;

static UIRuntime g_ui_runtime;

static void queue_action(UIActionType type, double value) {
    if (type == UI_ACTION_NONE) {
        return;
    }

    if (g_ui_runtime.action_count >= (int)(sizeof(g_ui_runtime.actions) / sizeof(g_ui_runtime.actions[0]))) {
        g_ui_runtime.action_head = (g_ui_runtime.action_head + 1) % (int)(sizeof(g_ui_runtime.actions) / sizeof(g_ui_runtime.actions[0]));
        g_ui_runtime.action_count--;
    }

    g_ui_runtime.actions[g_ui_runtime.action_tail].type = type;
    g_ui_runtime.actions[g_ui_runtime.action_tail].value = value;
    g_ui_runtime.action_tail = (g_ui_runtime.action_tail + 1) % (int)(sizeof(g_ui_runtime.actions) / sizeof(g_ui_runtime.actions[0]));
    g_ui_runtime.action_count++;
}

static double clamp_value(double value, double min_value, double max_value) {
    if (value < min_value) {
        return min_value;
    }
    if (value > max_value) {
        return max_value;
    }
    return value;
}

static void format_time(double seconds, char* out, size_t out_size) {
    if (!out || out_size == 0) {
        return;
    }

    if (seconds < 0.0) {
        seconds = 0.0;
    }

    int total = (int)(seconds + 0.5);
    int h = total / 3600;
    int m = (total % 3600) / 60;
    int s = total % 60;

    if (h > 0) {
        snprintf(out, out_size, "%d:%02d:%02d", h, m, s);
    } else {
        snprintf(out, out_size, "%02d:%02d", m, s);
    }
}

static const char* backend_status_label(int status) {
    switch (status) {
        case VIDEO_BACKEND_STATUS_SOFTWARE:
            return "software";
        case VIDEO_BACKEND_STATUS_INTEROP_HANDLE:
            return "interop-handle";
        case VIDEO_BACKEND_STATUS_TRUE_ZERO_COPY:
            return "true-zero-copy";
        case VIDEO_BACKEND_STATUS_FORCE_ZERO_COPY_BLOCKED:
            return "force-zero-copy-blocked";
        default:
            return "unknown";
    }
}

static const char* fallback_reason_label(int reason) {
    switch (reason) {
        case VIDEO_FALLBACK_REASON_NONE:
            return "none";
        case VIDEO_FALLBACK_REASON_UNSUPPORTED_MODE:
            return "unsupported-mode";
        case VIDEO_FALLBACK_REASON_BACKEND_FAILURE:
            return "backend-failure";
        case VIDEO_FALLBACK_REASON_IMPORT_FAILURE:
            return "import-failure";
        case VIDEO_FALLBACK_REASON_FORMAT_NOT_SUPPORTED:
            return "format-not-supported";
        default:
            return "unknown";
    }
}

static const char* hw_backend_label(int backend) {
    switch (backend) {
        case VIDEO_HW_BACKEND_NONE:
            return "none";
        case VIDEO_HW_BACKEND_VIDEOTOOLBOX:
            return "videotoolbox";
        case VIDEO_HW_BACKEND_D3D11VA:
            return "d3d11va";
        case VIDEO_HW_BACKEND_DXVA2:
            return "dxva2";
        default:
            return "unknown";
    }
}

static const char* hw_policy_label(int policy) {
    switch (policy) {
        case VIDEO_HW_POLICY_AUTO:
            return "auto";
        case VIDEO_HW_POLICY_OFF:
            return "off";
        case VIDEO_HW_POLICY_D3D11VA:
            return "d3d11va";
        case VIDEO_HW_POLICY_DXVA2:
            return "dxva2";
        case VIDEO_HW_POLICY_VIDEOTOOLBOX:
            return "videotoolbox";
        default:
            return "unknown";
    }
}

static const char* render_backend_label(const App* app) {
    if (!app) {
        return "unknown";
    }

    switch (app->render_backend) {
        case APP_RENDER_BACKEND_SDL:
            return "sdl";
        case APP_RENDER_BACKEND_VULKAN:
            return "vulkan";
        default:
            return "unknown";
    }
}

static void draw_debug_panel(const PlaybackSnapshot* snapshot) {
    if (!snapshot) {
        return;
    }

    const ImGuiViewport* viewport = ImGui::GetMainViewport();
    ImGui::SetNextWindowPos(ImVec2(viewport->Pos.x + 12.0f, viewport->Pos.y + 12.0f), ImGuiCond_Always);
    ImGui::SetNextWindowBgAlpha(0.78f);

    ImGuiWindowFlags flags = ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_AlwaysAutoResize |
                             ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoMove;
    if (!ImGui::Begin("Stats for Nerds", NULL, flags)) {
        ImGui::End();
        return;
    }

    ImGui::Text("Container: %s", snapshot->media_format[0] ? snapshot->media_format : "unknown");
    ImGui::Text("Mux Bitrate: %d kbps", snapshot->media_bitrate_kbps);
    ImGui::Separator();

    ImGui::Text("Video Codec: %s", snapshot->video_codec[0] ? snapshot->video_codec : "unknown");
    ImGui::Text("Video Bitrate: %d kbps", snapshot->video_bitrate_kbps);
    if (snapshot->video_fps_num > 0 && snapshot->video_fps_den > 0) {
        ImGui::Text("FPS: %.3f (%d/%d)",
                    (double)snapshot->video_fps_num / (double)snapshot->video_fps_den,
                    snapshot->video_fps_num,
                    snapshot->video_fps_den);
    } else {
        ImGui::TextUnformatted("FPS: unknown");
    }

    ImGui::Separator();
    if (snapshot->has_media) {
        ImGui::Text("Audio Codec: %s", snapshot->audio_codec[0] ? snapshot->audio_codec : "none");
        ImGui::Text("Audio Bitrate: %d kbps", snapshot->audio_bitrate_kbps);
        ImGui::Text("Audio: %d Hz / %d ch", snapshot->audio_sample_rate, snapshot->audio_channels);
    }

    ImGui::Separator();
    ImGui::Text("Render Backend: %s", render_backend_label(g_ui_runtime.app));
    ImGui::Text("HW Decode: %s", snapshot->video_hw_enabled ? "on" : "off");
    ImGui::Text("HW Backend: %s", hw_backend_label(snapshot->video_hw_backend));
    ImGui::Text("HW Policy: %s", hw_policy_label(snapshot->video_hw_policy));
    ImGui::Text("Interop Backend: %s", backend_status_label(snapshot->video_backend_status));
    ImGui::Text("Fallback: %s", fallback_reason_label(snapshot->video_fallback_reason));

    ImGui::End();
}

static void SDLCALL open_file_dialog_callback(void* userdata, const char* const* filelist, int filter) {
    (void)filter;

    UIRuntime* runtime = (UIRuntime*)userdata;
    if (!runtime || !runtime->file_mutex || !filelist || !filelist[0]) {
        return;
    }

    SDL_LockMutex(runtime->file_mutex);
    snprintf(runtime->selected_file, sizeof(runtime->selected_file), "%s", filelist[0]);
    runtime->has_selected_file = 1;
    SDL_UnlockMutex(runtime->file_mutex);
}

int ui_init(App* app) {
    memset(&g_ui_runtime, 0, sizeof(g_ui_runtime));
    g_ui_runtime.app = app;

    g_ui_runtime.file_mutex = SDL_CreateMutex();
    if (!g_ui_runtime.file_mutex) {
        return -1;
    }

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    ImGui::StyleColorsDark();

    if (app->render_backend == APP_RENDER_BACKEND_SDL) {
        if (!app->sdl_renderer) {
            ui_shutdown();
            return -1;
        }

        if (!ImGui_ImplSDL3_InitForSDLRenderer(app->window, app->sdl_renderer)) {
            ui_shutdown();
            return -1;
        }

        if (!ImGui_ImplSDLRenderer3_Init(app->sdl_renderer)) {
            ui_shutdown();
            return -1;
        }

        g_ui_runtime.use_sdl_renderer = 1;
        g_ui_runtime.initialized = 1;
        return 0;
    }

    if (!ImGui_ImplSDL3_InitForVulkan(app->window)) {
        ui_shutdown();
        return -1;
    }

    VkDescriptorPoolSize pool_sizes[] = {
        { VK_DESCRIPTOR_TYPE_SAMPLER, 1000 },
        { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1000 },
        { VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1000 },
        { VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1000 },
        { VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1000 },
        { VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 1000 },
        { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1000 },
        { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1000 },
        { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, 1000 },
        { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, 1000 },
        { VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, 1000 },
    };

    VkDescriptorPoolCreateInfo pool_info = {};
    pool_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    pool_info.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
    pool_info.maxSets = 1000 * (uint32_t)(sizeof(pool_sizes) / sizeof(pool_sizes[0]));
    pool_info.poolSizeCount = (uint32_t)(sizeof(pool_sizes) / sizeof(pool_sizes[0]));
    pool_info.pPoolSizes = pool_sizes;

    if (vkCreateDescriptorPool(app->device, &pool_info, NULL, &g_ui_runtime.descriptor_pool) != VK_SUCCESS) {
        ui_shutdown();
        return -1;
    }

    ImGui_ImplVulkan_InitInfo init_info = {};
    init_info.ApiVersion = VK_API_VERSION_1_3;
    init_info.Instance = app->instance;
    init_info.PhysicalDevice = app->gpu;
    init_info.Device = app->device;
    init_info.QueueFamily = app->graphics_queue_family;
    init_info.Queue = app->graphics_queue;
    init_info.DescriptorPool = g_ui_runtime.descriptor_pool;
    init_info.MinImageCount = app->swapchain_image_count > 1 ? app->swapchain_image_count : 2;
    init_info.ImageCount = app->swapchain_image_count;
    init_info.PipelineInfoMain.RenderPass = app->render_pass;
    init_info.PipelineInfoMain.Subpass = 0;
    init_info.PipelineInfoMain.MSAASamples = VK_SAMPLE_COUNT_1_BIT;

    if (!ImGui_ImplVulkan_Init(&init_info)) {
        ui_shutdown();
        return -1;
    }

    g_ui_runtime.initialized = 1;
    return 0;
}

void ui_shutdown(void) {
    if (!g_ui_runtime.use_sdl_renderer && g_ui_runtime.app && g_ui_runtime.app->device) {
        vkDeviceWaitIdle(g_ui_runtime.app->device);
    }

    if (g_ui_runtime.initialized) {
        if (g_ui_runtime.use_sdl_renderer) {
            ImGui_ImplSDLRenderer3_Shutdown();
        } else {
            ImGui_ImplVulkan_Shutdown();
        }
        ImGui_ImplSDL3_Shutdown();
        ImGui::DestroyContext();
        g_ui_runtime.initialized = 0;
    }

    if (!g_ui_runtime.use_sdl_renderer && g_ui_runtime.app && g_ui_runtime.app->device && g_ui_runtime.descriptor_pool) {
        vkDestroyDescriptorPool(g_ui_runtime.app->device, g_ui_runtime.descriptor_pool, NULL);
        g_ui_runtime.descriptor_pool = VK_NULL_HANDLE;
    }

    if (g_ui_runtime.file_mutex) {
        SDL_DestroyMutex(g_ui_runtime.file_mutex);
        g_ui_runtime.file_mutex = NULL;
    }

    g_ui_runtime.app = NULL;
    g_ui_runtime.has_selected_file = 0;
    g_ui_runtime.selected_file[0] = '\0';
    g_ui_runtime.action_head = 0;
    g_ui_runtime.action_tail = 0;
    g_ui_runtime.action_count = 0;
    g_ui_runtime.has_snapshot = 0;
    g_ui_runtime.use_sdl_renderer = 0;
}

void ui_on_swapchain_recreated(App* app) {
    if (!g_ui_runtime.initialized || g_ui_runtime.use_sdl_renderer) {
        return;
    }

    if (app) {
        g_ui_runtime.app = app;
    }

    if (!g_ui_runtime.app || !g_ui_runtime.app->device || !g_ui_runtime.app->render_pass) {
        return;
    }

    uint32_t min_image_count = g_ui_runtime.app->swapchain_image_count > 1 ? g_ui_runtime.app->swapchain_image_count : 2;
    ImGui_ImplVulkan_SetMinImageCount(min_image_count);

    ImGui_ImplVulkan_PipelineInfo pipeline_info = {};
    pipeline_info.RenderPass = g_ui_runtime.app->render_pass;
    pipeline_info.Subpass = 0;
    pipeline_info.MSAASamples = VK_SAMPLE_COUNT_1_BIT;
    ImGui_ImplVulkan_CreateMainPipeline(&pipeline_info);
}

void ui_new_frame(void) {
    if (!g_ui_runtime.initialized) {
        return;
    }

    if (g_ui_runtime.use_sdl_renderer) {
        ImGui_ImplSDLRenderer3_NewFrame();
    } else {
        if (g_ui_runtime.app && g_ui_runtime.app->swapchain_image_count >= 2) {
            ImGui_ImplVulkan_SetMinImageCount(g_ui_runtime.app->swapchain_image_count);
        }
        ImGui_ImplVulkan_NewFrame();
    }

    ImGui_ImplSDL3_NewFrame();
    ImGui::NewFrame();
}

void ui_render(UIState* ui, const PlaybackSnapshot* snapshot) {
    if (!g_ui_runtime.initialized || !ui || !snapshot) {
        return;
    }

    g_ui_runtime.snapshot = *snapshot;
    g_ui_runtime.has_snapshot = 1;
    PlayerState state = snapshot->state;
    int has_media = snapshot->has_media;

    const ImGuiViewport* viewport = ImGui::GetMainViewport();
    const float panel_padding_x = 12.0f;
    const float panel_padding_y = 4.0f;
    const float panel_item_spacing_y = 4.0f;
    const float frame_h = ImGui::GetFrameHeight();
    const float text_h = ImGui::GetTextLineHeight();
    float panel_height = (panel_padding_y * 2.0f) + frame_h + panel_item_spacing_y + frame_h + panel_item_spacing_y + text_h;
    if (panel_height < 64.0f) {
        panel_height = 64.0f;
    }
    ImGui::SetNextWindowPos(ImVec2(viewport->Pos.x, viewport->Pos.y + viewport->Size.y - panel_height));
    ImGui::SetNextWindowSize(ImVec2(viewport->Size.x, panel_height));

    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 0.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(panel_padding_x, panel_padding_y));
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(ImGui::GetStyle().ItemSpacing.x, panel_item_spacing_y));
    ImGui::SetNextWindowBgAlpha(0.84f);

    ImGuiWindowFlags flags = ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove |
                             ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoSavedSettings;
    if (ImGui::Begin("Playback Controller", NULL, flags)) {
        if (ImGui::Button("Open")) {
            const SDL_DialogFileFilter filters[] = {
                { "Video", "mp4;m4v;mov;mkv;webm;avi;ts;flv;wmv" },
                { "All Files", "*" },
            };
            SDL_ShowOpenFileDialog(open_file_dialog_callback, &g_ui_runtime, g_ui_runtime.app ? g_ui_runtime.app->window : NULL, filters, 2, NULL, false);
        }

        ImGui::SameLine();
        if (!has_media) {
            ImGui::BeginDisabled();
        }
        if (state == PLAYER_STATE_PLAYING) {
            if (ImGui::Button("Pause")) {
                queue_action(UI_ACTION_PAUSE, 0.0);
            }
        } else {
            if (ImGui::Button("Play")) {
                queue_action(UI_ACTION_PLAY, 0.0);
            }
        }

        ImGui::SameLine();
        if (ImGui::Button("Stop")) {
            queue_action(UI_ACTION_STOP, 0.0);
        }
        if (!has_media) {
            ImGui::EndDisabled();
        }

        char current_time_text[32];
        char duration_text[32];
        format_time(snapshot->current_time, current_time_text, sizeof(current_time_text));
        format_time(snapshot->duration, duration_text, sizeof(duration_text));

        ImGui::SameLine();
        ImGui::Text("%s / %s", current_time_text, duration_text);

        float available_width = ImGui::GetContentRegionAvail().x;
        float seek_width = available_width - 310.0f;
        if (seek_width < 120.0f) {
            seek_width = 120.0f;
        }
        ImGui::SetNextItemWidth(seek_width);

        float max_seek = snapshot->duration > 0.0 ? (float)snapshot->duration : 0.0f;
        float seek_value = ui->seek_changed ? ui->seek_value : (float)snapshot->current_time;
        if (max_seek > 0.0f) {
            seek_value = (float)clamp_value((double)seek_value, 0.0, (double)max_seek);
            if (ImGui::SliderFloat("##seek", &seek_value, 0.0f, max_seek, "")) {
                ui->seek_changed = 1;
                ui->seek_value = seek_value;
            }
            if (ui->seek_changed && ImGui::IsItemDeactivatedAfterEdit()) {
                queue_action(UI_ACTION_SEEK_ABS, (double)ui->seek_value);
                ui->seek_changed = 0;
            }
        } else {
            ImGui::BeginDisabled();
            ImGui::SliderFloat("##seek", &seek_value, 0.0f, 1.0f, "");
            ImGui::EndDisabled();
            ui->seek_changed = 0;
        }

        ImGui::SameLine();
        ImGui::SetNextItemWidth(140.0f);
        float volume = (float)snapshot->volume;
        if (ImGui::SliderFloat("Vol", &volume, 0.0f, 1.0f, "%.2f")) {
            queue_action(UI_ACTION_SET_VOLUME, (double)volume);
        }

        ImGui::SameLine();
        ImGui::SetNextItemWidth(140.0f);
        float speed = (float)snapshot->playback_speed;
        if (ImGui::SliderFloat("Speed", &speed, 0.25f, 2.0f, "%.2fx")) {
            queue_action(UI_ACTION_SET_SPEED, (double)speed);
        }

        ImGui::SameLine();
        if (ImGui::Button(g_ui_runtime.show_debug_panel ? "Hide Stats" : "Show Stats")) {
            g_ui_runtime.show_debug_panel = !g_ui_runtime.show_debug_panel;
        }

    }
    ImGui::End();
    ImGui::PopStyleVar(4);

    if (g_ui_runtime.show_debug_panel && snapshot && snapshot->has_media) {
        draw_debug_panel(snapshot);
    }

    ImGui::Render();
}

void ui_draw(VkCommandBuffer cmd) {
    if (!g_ui_runtime.initialized) {
        return;
    }

    if (g_ui_runtime.use_sdl_renderer) {
        if (g_ui_runtime.app && g_ui_runtime.app->sdl_renderer) {
            ImGui_ImplSDLRenderer3_RenderDrawData(ImGui::GetDrawData(), g_ui_runtime.app->sdl_renderer);
        }
        return;
    }

    if (cmd == VK_NULL_HANDLE) {
        return;
    }

    ImGui_ImplVulkan_RenderDrawData(ImGui::GetDrawData(), cmd);
}

void ui_process_event(void* event) {
    if (!g_ui_runtime.initialized || !event) {
        return;
    }

    const SDL_Event* sdl_event = (const SDL_Event*)event;
    ImGui_ImplSDL3_ProcessEvent(sdl_event);

    if (!g_ui_runtime.has_snapshot) {
        return;
    }
    if (sdl_event->type != SDL_EVENT_KEY_DOWN || sdl_event->key.repeat) {
        return;
    }

    if (sdl_event->key.key == SDLK_I) {
        g_ui_runtime.show_debug_panel = !g_ui_runtime.show_debug_panel;
        return;
    }

    ImGuiIO& io = ImGui::GetIO();
    if (io.WantCaptureKeyboard) {
        return;
    }
    if (!g_ui_runtime.snapshot.has_media) {
        return;
    }

    if (sdl_event->key.key == SDLK_SPACE) {
        queue_action(UI_ACTION_TOGGLE_PLAY_PAUSE, 0.0);
        return;
    }

    if (sdl_event->key.key == SDLK_LEFT || sdl_event->key.key == SDLK_RIGHT) {
        double step = (sdl_event->key.mod & SDL_KMOD_SHIFT) ? 10.0 : 5.0;
        if (sdl_event->key.key == SDLK_LEFT) {
            step = -step;
        }
        double target = g_ui_runtime.snapshot.current_time + step;
        if (g_ui_runtime.snapshot.duration > 0.0) {
            target = clamp_value(target, 0.0, g_ui_runtime.snapshot.duration);
        } else if (target < 0.0) {
            target = 0.0;
        }
        queue_action(UI_ACTION_SEEK_ABS, target);
        return;
    }

    if (sdl_event->key.key == SDLK_UP || sdl_event->key.key == SDLK_DOWN) {
        double step = (sdl_event->key.mod & SDL_KMOD_SHIFT) ? 0.10 : 0.05;
        if (sdl_event->key.key == SDLK_DOWN) {
            step = -step;
        }
        queue_action(UI_ACTION_SET_VOLUME, g_ui_runtime.snapshot.volume + step);
    }
}

int ui_take_selected_file(char* path, size_t path_size) {
    if (!path || path_size == 0 || !g_ui_runtime.file_mutex) {
        return 0;
    }

    int has_file = 0;

    SDL_LockMutex(g_ui_runtime.file_mutex);
    if (g_ui_runtime.has_selected_file) {
        snprintf(path, path_size, "%s", g_ui_runtime.selected_file);
        g_ui_runtime.has_selected_file = 0;
        g_ui_runtime.selected_file[0] = '\0';
        has_file = 1;
    }
    SDL_UnlockMutex(g_ui_runtime.file_mutex);

    return has_file;
}

int ui_take_action(UIAction* action) {
    if (!action || g_ui_runtime.action_count <= 0) {
        return 0;
    }

    *action = g_ui_runtime.actions[g_ui_runtime.action_head];
    g_ui_runtime.action_head = (g_ui_runtime.action_head + 1) % (int)(sizeof(g_ui_runtime.actions) / sizeof(g_ui_runtime.actions[0]));
    g_ui_runtime.action_count--;
    return 1;
}
