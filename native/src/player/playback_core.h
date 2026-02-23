#ifndef CPLAYER_PLAYBACK_CORE_H
#define CPLAYER_PLAYBACK_CORE_H

#include <SDL3/SDL.h>
#include <stddef.h>
#include <stdint.h>
#include "player/player.h"
#include "audio/audio_output.h"
#include "video/video_pipeline.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    PLAYBACK_CMD_OPEN,
    PLAYBACK_CMD_PLAY,
    PLAYBACK_CMD_PAUSE,
    PLAYBACK_CMD_STOP,
    PLAYBACK_CMD_TOGGLE_PLAY_PAUSE,
    PLAYBACK_CMD_SEEK_ABS,
    PLAYBACK_CMD_SET_VOLUME,
    PLAYBACK_CMD_SET_SPEED,
    PLAYBACK_CMD_SHUTDOWN,
} PlaybackCommandType;

typedef struct {
    PlaybackCommandType type;
    double value;
    char path[1024];
} PlaybackCommand;

typedef enum {
    VIDEO_BACKEND_STATUS_SOFTWARE = 0,
    VIDEO_BACKEND_STATUS_INTEROP_HANDLE = 1,
    VIDEO_BACKEND_STATUS_TRUE_ZERO_COPY = 2,
    VIDEO_BACKEND_STATUS_FORCE_ZERO_COPY_BLOCKED = 3,
} VideoBackendStatus;

typedef enum {
    VIDEO_FALLBACK_REASON_NONE = 0,
    VIDEO_FALLBACK_REASON_UNSUPPORTED_MODE = 1,
    VIDEO_FALLBACK_REASON_BACKEND_FAILURE = 2,
    VIDEO_FALLBACK_REASON_IMPORT_FAILURE = 3,
    VIDEO_FALLBACK_REASON_FORMAT_NOT_SUPPORTED = 4,
} VideoFallbackReason;

typedef struct {
    PlayerState state;
    double current_time;
    double duration;
    double volume;
    double playback_speed;
    int has_media;
    int video_backend_status;
    int video_fallback_reason;
} PlaybackSnapshot;

typedef struct {
    Player* player;
    AudioOutput* audio_output;
    VideoPipeline* video_pipeline;

    SDL_Thread* thread;
    SDL_Mutex* queue_mutex;
    SDL_Condition* queue_cond;
    SDL_Mutex* snapshot_mutex;
    SDL_Mutex* media_mutex;

    PlaybackCommand queue[64];
    int queue_head;
    int queue_tail;
    int queue_count;

    SDL_AtomicInt running;
    int audio_output_initialized;
    int video_pipeline_initialized;

    uint8_t* render_buffer;
    size_t render_buffer_size;

    PlaybackSnapshot snapshot;
} PlaybackCore;

int playback_core_init(PlaybackCore* core, Player* player, AudioOutput* audio_output, VideoPipeline* video_pipeline);
int playback_core_start(PlaybackCore* core);
void playback_core_destroy(PlaybackCore* core);

int playback_core_open(PlaybackCore* core, const char* path);
int playback_core_play(PlaybackCore* core);
int playback_core_pause(PlaybackCore* core);
int playback_core_stop(PlaybackCore* core);
int playback_core_toggle_play_pause(PlaybackCore* core);
int playback_core_seek_abs(PlaybackCore* core, double time);
int playback_core_set_volume(PlaybackCore* core, double volume);
int playback_core_set_speed(PlaybackCore* core, double speed);

int playback_core_get_snapshot(PlaybackCore* core, PlaybackSnapshot* out_snapshot);
int playback_core_get_frame_for_render(PlaybackCore* core, double master_clock, uint8_t** data, int* width, int* height, int* linesize);

#ifdef __cplusplus
}
#endif

#endif
