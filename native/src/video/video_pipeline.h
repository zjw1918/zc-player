#ifndef CPLAYER_VIDEO_PIPELINE_H
#define CPLAYER_VIDEO_PIPELINE_H

#include <SDL3/SDL.h>
#include <stdint.h>
#include "player/player.h"

#define VIDEO_FRAME_QUEUE_CAPACITY 4

typedef struct {
    uint8_t* planes[3];
    size_t plane_sizes[3];
    int linesizes[3];
    int plane_count;
    int format;
    int source_hw;
    uint64_t gpu_token;
    int width;
    int height;
    double pts;
} VideoPipelineFrame;

typedef struct {
    Player* player;
    SDL_Thread* decode_thread;
    int decode_running;

    VideoPipelineFrame frames[VIDEO_FRAME_QUEUE_CAPACITY];
    int head;
    int tail;
    int count;
    SDL_Mutex* queue_mutex;
    SDL_Condition* can_push;

    uint8_t* upload_planes[3];
    size_t upload_plane_sizes[3];
    int upload_plane_count;
    int have_pending_upload;
    int pending_width;
    int pending_height;
    int pending_linesizes[3];
    int pending_plane_count;
    int pending_format;
    int pending_source_hw;
    uint64_t pending_gpu_token;
    uint64_t delivered_gpu_token;
    double pending_pts;

    int true_zero_copy_active;

    double clock_base_pts;
    Uint64 clock_base_time_ns;
    double expected_start_pts;
    int pts_offset_valid;
    double pts_offset;
} VideoPipeline;

int video_pipeline_init(VideoPipeline* pipeline, Player* player);
int video_pipeline_start(VideoPipeline* pipeline);
void video_pipeline_stop(VideoPipeline* pipeline);
void video_pipeline_reset(VideoPipeline* pipeline);
void video_pipeline_destroy(VideoPipeline* pipeline);
int video_pipeline_get_frame_for_render(
    VideoPipeline* pipeline,
    double master_clock,
    uint8_t** planes,
    int* width,
    int* height,
    int* linesizes,
    int* plane_count,
    int* format,
    int* source_hw,
    uint64_t* gpu_token
);

void video_pipeline_set_true_zero_copy_active(VideoPipeline* pipeline, int active);

#endif
