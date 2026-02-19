#include "video_pipeline.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int queue_push_locked(VideoPipeline* pipeline, uint8_t* src_data, int src_linesize, int width, int height, double pts) {
    if (pipeline->count >= VIDEO_FRAME_QUEUE_CAPACITY) {
        return -1;
    }

    size_t row_size = (size_t)width * 4;
    if (src_linesize < (int)row_size) {
        return -1;
    }

    VideoPipelineFrame* frame = &pipeline->frames[pipeline->tail];
    if (frame->width != width || frame->height != height || frame->linesize < (int)row_size) {
        return -1;
    }

    for (int y = 0; y < height; y++) {
        memcpy(frame->data + ((size_t)y * frame->linesize), src_data + ((size_t)y * src_linesize), row_size);
    }

    frame->pts = pts;
    pipeline->tail = (pipeline->tail + 1) % VIDEO_FRAME_QUEUE_CAPACITY;
    pipeline->count++;
    return 0;
}

static int queue_pop_to_upload_locked(VideoPipeline* pipeline) {
    if (pipeline->count == 0) {
        return -1;
    }

    VideoPipelineFrame* frame = &pipeline->frames[pipeline->head];
    size_t frame_size = (size_t)frame->linesize * (size_t)frame->height;
    if (pipeline->upload_buffer_size < frame_size) {
        return -1;
    }

    memcpy(pipeline->upload_buffer, frame->data, frame_size);
    pipeline->pending_width = frame->width;
    pipeline->pending_height = frame->height;
    pipeline->pending_linesize = frame->linesize;
    pipeline->pending_pts = frame->pts;
    pipeline->have_pending_upload = 1;

    pipeline->head = (pipeline->head + 1) % VIDEO_FRAME_QUEUE_CAPACITY;
    pipeline->count--;
    SDL_SignalCondition(pipeline->can_push);
    return 0;
}

static double fallback_video_clock(VideoPipeline* pipeline, double frame_pts) {
    Uint64 now_ns = SDL_GetTicksNS();

    if (pipeline->clock_base_pts < 0.0 || frame_pts < pipeline->clock_base_pts) {
        pipeline->clock_base_pts = frame_pts;
        pipeline->clock_base_time_ns = now_ns;
    }

    double elapsed_seconds = (double)(now_ns - pipeline->clock_base_time_ns) / 1000000000.0;
    elapsed_seconds *= player_get_playback_speed(pipeline->player);
    return pipeline->clock_base_pts + elapsed_seconds;
}

static int decode_thread_main(void* userdata) {
    VideoPipeline* pipeline = (VideoPipeline*)userdata;

    while (1) {
        SDL_LockMutex(pipeline->queue_mutex);
        while (pipeline->decode_running && pipeline->count >= VIDEO_FRAME_QUEUE_CAPACITY) {
            SDL_WaitCondition(pipeline->can_push, pipeline->queue_mutex);
        }
        int running = pipeline->decode_running;
        SDL_UnlockMutex(pipeline->queue_mutex);

        if (!running) {
            break;
        }

        if (player_get_state(pipeline->player) != PLAYER_STATE_PLAYING) {
            SDL_Delay(2);
            continue;
        }

        if (player_decode_frame(pipeline->player) != 0) {
            SDL_Delay(1);
            continue;
        }

        uint8_t* data = NULL;
        int linesize = 0;
        if (player_get_video_frame(pipeline->player, &data, &linesize) != 0) {
            SDL_Delay(1);
            continue;
        }

        double pts = player_get_video_pts(pipeline->player);

        SDL_LockMutex(pipeline->queue_mutex);
        if (pipeline->decode_running) {
            if (!pipeline->pts_offset_valid) {
                pipeline->pts_offset = pts - pipeline->expected_start_pts;
                pipeline->pts_offset_valid = 1;
            }

            double adjusted_pts = pts - pipeline->pts_offset;
            if (queue_push_locked(pipeline, data, linesize, pipeline->player->width, pipeline->player->height, adjusted_pts) != 0) {
                SDL_UnlockMutex(pipeline->queue_mutex);
                SDL_Delay(1);
                continue;
            }
        }
        running = pipeline->decode_running;
        SDL_UnlockMutex(pipeline->queue_mutex);

        if (!running) {
            break;
        }
    }

    return 0;
}

int video_pipeline_init(VideoPipeline* pipeline, Player* player) {
    memset(pipeline, 0, sizeof(VideoPipeline));
    pipeline->player = player;
    pipeline->clock_base_pts = -1.0;
    pipeline->expected_start_pts = player->current_time;

    int width = player->width;
    int height = player->height;
    if (width <= 0 || height <= 0) {
        return -1;
    }

    pipeline->queue_mutex = SDL_CreateMutex();
    if (!pipeline->queue_mutex) {
        return -1;
    }

    pipeline->can_push = SDL_CreateCondition();
    if (!pipeline->can_push) {
        SDL_DestroyMutex(pipeline->queue_mutex);
        pipeline->queue_mutex = NULL;
        return -1;
    }

    size_t frame_size = (size_t)width * (size_t)height * 4;
    int linesize = width * 4;

    for (int i = 0; i < VIDEO_FRAME_QUEUE_CAPACITY; i++) {
        pipeline->frames[i].data = malloc(frame_size);
        if (!pipeline->frames[i].data) {
            video_pipeline_destroy(pipeline);
            return -1;
        }
        pipeline->frames[i].width = width;
        pipeline->frames[i].height = height;
        pipeline->frames[i].linesize = linesize;
        pipeline->frames[i].pts = 0.0;
    }

    pipeline->upload_buffer = malloc(frame_size);
    if (!pipeline->upload_buffer) {
        video_pipeline_destroy(pipeline);
        return -1;
    }
    pipeline->upload_buffer_size = frame_size;

    return 0;
}

int video_pipeline_start(VideoPipeline* pipeline) {
    if (pipeline->decode_thread) {
        return 0;
    }

    pipeline->decode_running = 1;
    pipeline->decode_thread = SDL_CreateThread(decode_thread_main, "video_decode", pipeline);
    if (!pipeline->decode_thread) {
        pipeline->decode_running = 0;
        return -1;
    }

    return 0;
}

void video_pipeline_stop(VideoPipeline* pipeline) {
    if (!pipeline->decode_thread || !pipeline->queue_mutex) {
        return;
    }

    SDL_LockMutex(pipeline->queue_mutex);
    pipeline->decode_running = 0;
    SDL_BroadcastCondition(pipeline->can_push);
    SDL_UnlockMutex(pipeline->queue_mutex);

    SDL_WaitThread(pipeline->decode_thread, NULL);
    pipeline->decode_thread = NULL;
}

void video_pipeline_reset(VideoPipeline* pipeline) {
    if (!pipeline || !pipeline->queue_mutex) {
        return;
    }

    SDL_LockMutex(pipeline->queue_mutex);
    pipeline->head = 0;
    pipeline->tail = 0;
    pipeline->count = 0;
    pipeline->have_pending_upload = 0;
    pipeline->pending_width = 0;
    pipeline->pending_height = 0;
    pipeline->pending_linesize = 0;
    pipeline->pending_pts = 0.0;
    pipeline->clock_base_pts = -1.0;
    pipeline->clock_base_time_ns = 0;
    pipeline->expected_start_pts = pipeline->player ? pipeline->player->current_time : 0.0;
    pipeline->pts_offset_valid = 0;
    pipeline->pts_offset = 0.0;
    SDL_BroadcastCondition(pipeline->can_push);
    SDL_UnlockMutex(pipeline->queue_mutex);
}

void video_pipeline_destroy(VideoPipeline* pipeline) {
    video_pipeline_stop(pipeline);

    if (pipeline->upload_buffer) {
        free(pipeline->upload_buffer);
        pipeline->upload_buffer = NULL;
        pipeline->upload_buffer_size = 0;
    }

    for (int i = 0; i < VIDEO_FRAME_QUEUE_CAPACITY; i++) {
        if (pipeline->frames[i].data) {
            free(pipeline->frames[i].data);
            pipeline->frames[i].data = NULL;
        }
    }

    if (pipeline->can_push) {
        SDL_DestroyCondition(pipeline->can_push);
        pipeline->can_push = NULL;
    }

    if (pipeline->queue_mutex) {
        SDL_DestroyMutex(pipeline->queue_mutex);
        pipeline->queue_mutex = NULL;
    }

    pipeline->head = 0;
    pipeline->tail = 0;
    pipeline->count = 0;
    pipeline->decode_running = 0;
    pipeline->have_pending_upload = 0;
    pipeline->clock_base_pts = -1.0;
    pipeline->clock_base_time_ns = 0;
    pipeline->expected_start_pts = 0.0;
    pipeline->pts_offset_valid = 0;
    pipeline->pts_offset = 0.0;
}

int video_pipeline_get_frame_for_render(VideoPipeline* pipeline, double master_clock, uint8_t** data, int* width, int* height, int* linesize) {
    if (!pipeline || !data || !width || !height || !linesize) {
        return -1;
    }

    if (!pipeline->have_pending_upload) {
        SDL_LockMutex(pipeline->queue_mutex);
        if (pipeline->count > 0) {
            queue_pop_to_upload_locked(pipeline);
        }
        SDL_UnlockMutex(pipeline->queue_mutex);
    }

    if (!pipeline->have_pending_upload) {
        return 0;
    }

    if (master_clock < 0.0) {
        master_clock = fallback_video_clock(pipeline, pipeline->pending_pts);
    }

    double frame_delay = pipeline->pending_pts - master_clock;
    if (frame_delay <= 0.002) {
        *data = pipeline->upload_buffer;
        *width = pipeline->pending_width;
        *height = pipeline->pending_height;
        *linesize = pipeline->pending_linesize;
        pipeline->have_pending_upload = 0;
        return 1;
    }

    return 0;
}
