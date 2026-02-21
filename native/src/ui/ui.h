#ifndef CPLAYER_UI_H
#define CPLAYER_UI_H

#include <stddef.h>
#include <vulkan/vulkan.h>
#include "app/app.h"
#include "player/playback_core.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int seek_changed;
    float seek_value;
} UIState;

typedef enum {
    UI_ACTION_NONE,
    UI_ACTION_PLAY,
    UI_ACTION_PAUSE,
    UI_ACTION_STOP,
    UI_ACTION_TOGGLE_PLAY_PAUSE,
    UI_ACTION_SEEK_ABS,
    UI_ACTION_SET_VOLUME,
    UI_ACTION_SET_SPEED,
} UIActionType;

typedef struct {
    UIActionType type;
    double value;
} UIAction;

int ui_init(App* app);
void ui_shutdown(void);
void ui_on_swapchain_recreated(App* app);
void ui_new_frame(void);
void ui_render(UIState* ui, const PlaybackSnapshot* snapshot);
void ui_draw(VkCommandBuffer cmd);
void ui_process_event(void* event);
int ui_take_selected_file(char* path, size_t path_size);
int ui_take_action(UIAction* action);

#ifdef __cplusplus
}
#endif

#endif
