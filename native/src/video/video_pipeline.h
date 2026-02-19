#ifndef CPLAYER_VIDEO_PIPELINE_H
#define CPLAYER_VIDEO_PIPELINE_H

#include <SDL3/SDL.h>
#include <stdint.h>
#include "player/player.h"

#define VIDEO_FRAME_QUEUE_CAPACITY 8

typedef struct {
    uint8_t* data;
    int width;
    int height;
    int linesize;
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

    uint8_t* upload_buffer;
    size_t upload_buffer_size;
    int have_pending_upload;
    int pending_width;
    int pending_height;
    int pending_linesize;
    double pending_pts;

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
int video_pipeline_get_frame_for_render(VideoPipeline* pipeline, double master_clock, uint8_t** data, int* width, int* height, int* linesize);

#endif
