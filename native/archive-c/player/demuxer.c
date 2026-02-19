#include "demuxer.h"
#include <stdio.h>
#include <string.h>

static void packet_queue_clear(DemuxerPacketQueue* queue) {
    while (queue->count > 0) {
        AVPacket* packet = queue->packets[queue->head];
        queue->packets[queue->head] = NULL;
        queue->head = (queue->head + 1) % DEMUXER_PACKET_QUEUE_CAPACITY;
        queue->count--;
        if (packet) {
            av_packet_free(&packet);
        }
    }
    queue->head = 0;
    queue->tail = 0;
}

static int packet_queue_push(DemuxerPacketQueue* queue, const AVPacket* src_packet) {
    if (queue->count >= DEMUXER_PACKET_QUEUE_CAPACITY) {
        return -1;
    }

    AVPacket* packet = av_packet_alloc();
    if (!packet) {
        return -1;
    }

    if (av_packet_ref(packet, src_packet) < 0) {
        av_packet_free(&packet);
        return -1;
    }

    queue->packets[queue->tail] = packet;
    queue->tail = (queue->tail + 1) % DEMUXER_PACKET_QUEUE_CAPACITY;
    queue->count++;
    return 0;
}

static int packet_queue_pop(DemuxerPacketQueue* queue, AVPacket* dst_packet) {
    if (queue->count <= 0) {
        return -1;
    }

    AVPacket* packet = queue->packets[queue->head];
    queue->packets[queue->head] = NULL;
    queue->head = (queue->head + 1) % DEMUXER_PACKET_QUEUE_CAPACITY;
    queue->count--;

    av_packet_move_ref(dst_packet, packet);
    av_packet_free(&packet);
    return 0;
}

static int demux_thread_main(void* userdata) {
    Demuxer* demuxer = (Demuxer*)userdata;
    AVPacket* packet = av_packet_alloc();
    if (!packet) {
        SDL_LockMutex(demuxer->mutex);
        demuxer->eof = 1;
        demuxer->thread_running = 0;
        SDL_BroadcastCondition(demuxer->can_read_video);
        SDL_BroadcastCondition(demuxer->can_read_audio);
        SDL_BroadcastCondition(demuxer->can_write);
        SDL_UnlockMutex(demuxer->mutex);
        return -1;
    }

    while (1) {
        SDL_LockMutex(demuxer->mutex);
        int stop_requested = demuxer->stop_requested;
        SDL_UnlockMutex(demuxer->mutex);
        if (stop_requested) {
            break;
        }

        int ret = av_read_frame(demuxer->fmt_ctx, packet);
        if (ret < 0) {
            SDL_LockMutex(demuxer->mutex);
            demuxer->eof = 1;
            SDL_BroadcastCondition(demuxer->can_read_video);
            SDL_BroadcastCondition(demuxer->can_read_audio);
            SDL_BroadcastCondition(demuxer->can_write);
            SDL_UnlockMutex(demuxer->mutex);
            break;
        }

        SDL_LockMutex(demuxer->mutex);
        DemuxerPacketQueue* queue = NULL;
        SDL_Condition* can_read = NULL;

        if (packet->stream_index == demuxer->video_stream_index) {
            queue = &demuxer->video_queue;
            can_read = demuxer->can_read_video;
        } else if (packet->stream_index == demuxer->audio_stream_index) {
            queue = &demuxer->audio_queue;
            can_read = demuxer->can_read_audio;
        }

        while (queue && !demuxer->stop_requested && queue->count >= DEMUXER_PACKET_QUEUE_CAPACITY) {
            SDL_WaitCondition(demuxer->can_write, demuxer->mutex);
        }

        if (queue && !demuxer->stop_requested) {
            if (packet_queue_push(queue, packet) != 0) {
                demuxer->stop_requested = 1;
                demuxer->eof = 1;
                SDL_BroadcastCondition(demuxer->can_read_video);
                SDL_BroadcastCondition(demuxer->can_read_audio);
                SDL_BroadcastCondition(demuxer->can_write);
            } else {
                SDL_SignalCondition(can_read);
            }
        }

        int should_stop = demuxer->stop_requested;
        SDL_UnlockMutex(demuxer->mutex);

        av_packet_unref(packet);

        if (should_stop) {
            break;
        }
    }

    av_packet_free(&packet);

    SDL_LockMutex(demuxer->mutex);
    demuxer->thread_running = 0;
    SDL_BroadcastCondition(demuxer->can_read_video);
    SDL_BroadcastCondition(demuxer->can_read_audio);
    SDL_BroadcastCondition(demuxer->can_write);
    SDL_UnlockMutex(demuxer->mutex);

    return 0;
}

int demuxer_open(Demuxer* demuxer, const char* filepath) {
    memset(demuxer, 0, sizeof(Demuxer));
    demuxer->video_stream_index = -1;
    demuxer->audio_stream_index = -1;

    if (avformat_open_input(&demuxer->fmt_ctx, filepath, NULL, NULL) != 0) {
        fprintf(stderr, "Failed to open file: %s\n", filepath);
        goto fail;
    }

    if (avformat_find_stream_info(demuxer->fmt_ctx, NULL) < 0) {
        fprintf(stderr, "Failed to find stream info\n");
        goto fail;
    }

    for (unsigned int i = 0; i < demuxer->fmt_ctx->nb_streams; i++) {
        AVStream* stream = demuxer->fmt_ctx->streams[i];
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && demuxer->video_stream_index < 0) {
            demuxer->video_stream_index = (int)i;
            demuxer->video_stream = stream;
        }
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && demuxer->audio_stream_index < 0) {
            demuxer->audio_stream_index = (int)i;
            demuxer->audio_stream = stream;
        }
    }

    if (demuxer->video_stream_index < 0 || !demuxer->video_stream) {
        fprintf(stderr, "No video stream found\n");
        goto fail;
    }

    demuxer->mutex = SDL_CreateMutex();
    if (!demuxer->mutex) {
        goto fail;
    }

    demuxer->can_read_video = SDL_CreateCondition();
    if (!demuxer->can_read_video) {
        goto fail;
    }

    demuxer->can_read_audio = SDL_CreateCondition();
    if (!demuxer->can_read_audio) {
        goto fail;
    }

    demuxer->can_write = SDL_CreateCondition();
    if (!demuxer->can_write) {
        goto fail;
    }

    return 0;

fail:
    demuxer_close(demuxer);
    return -1;
}

int demuxer_start(Demuxer* demuxer) {
    if (!demuxer || !demuxer->fmt_ctx || !demuxer->mutex) {
        return -1;
    }

    if (demuxer->thread) {
        return 0;
    }

    SDL_LockMutex(demuxer->mutex);
    demuxer->stop_requested = 0;
    demuxer->eof = 0;
    demuxer->thread_running = 1;
    SDL_UnlockMutex(demuxer->mutex);

    demuxer->thread = SDL_CreateThread(demux_thread_main, "demux", demuxer);
    if (!demuxer->thread) {
        SDL_LockMutex(demuxer->mutex);
        demuxer->thread_running = 0;
        SDL_UnlockMutex(demuxer->mutex);
        return -1;
    }

    return 0;
}

void demuxer_stop(Demuxer* demuxer) {
    if (!demuxer) {
        return;
    }

    if (demuxer->mutex) {
        SDL_LockMutex(demuxer->mutex);
        demuxer->stop_requested = 1;
        if (demuxer->can_read_video) {
            SDL_BroadcastCondition(demuxer->can_read_video);
        }
        if (demuxer->can_read_audio) {
            SDL_BroadcastCondition(demuxer->can_read_audio);
        }
        if (demuxer->can_write) {
            SDL_BroadcastCondition(demuxer->can_write);
        }
        SDL_UnlockMutex(demuxer->mutex);
    }

    if (demuxer->thread) {
        SDL_WaitThread(demuxer->thread, NULL);
        demuxer->thread = NULL;
    }

    if (demuxer->mutex) {
        SDL_LockMutex(demuxer->mutex);
        demuxer->thread_running = 0;
        SDL_UnlockMutex(demuxer->mutex);
    }
}

void demuxer_close(Demuxer* demuxer) {
    if (!demuxer) {
        return;
    }

    demuxer_stop(demuxer);

    if (demuxer->mutex) {
        SDL_LockMutex(demuxer->mutex);
        packet_queue_clear(&demuxer->video_queue);
        packet_queue_clear(&demuxer->audio_queue);
        SDL_UnlockMutex(demuxer->mutex);
    }

    if (demuxer->can_write) {
        SDL_DestroyCondition(demuxer->can_write);
        demuxer->can_write = NULL;
    }

    if (demuxer->can_read_audio) {
        SDL_DestroyCondition(demuxer->can_read_audio);
        demuxer->can_read_audio = NULL;
    }

    if (demuxer->can_read_video) {
        SDL_DestroyCondition(demuxer->can_read_video);
        demuxer->can_read_video = NULL;
    }

    if (demuxer->mutex) {
        SDL_DestroyMutex(demuxer->mutex);
        demuxer->mutex = NULL;
    }

    if (demuxer->fmt_ctx) {
        avformat_close_input(&demuxer->fmt_ctx);
    }

    demuxer->video_stream_index = -1;
    demuxer->audio_stream_index = -1;
    demuxer->video_stream = NULL;
    demuxer->audio_stream = NULL;
    demuxer->thread_running = 0;
    demuxer->stop_requested = 0;
    demuxer->eof = 0;
}

int demuxer_seek(Demuxer* demuxer, double time_seconds) {
    if (!demuxer || !demuxer->fmt_ctx || !demuxer->mutex) {
        return -1;
    }

    if (time_seconds < 0.0) {
        time_seconds = 0.0;
    }

    demuxer_stop(demuxer);

    int64_t target_ts = (int64_t)(time_seconds * (double)AV_TIME_BASE);
    int seek_ret = avformat_seek_file(demuxer->fmt_ctx, -1, INT64_MIN, target_ts, INT64_MAX, AVSEEK_FLAG_BACKWARD);
    if (seek_ret < 0) {
        seek_ret = av_seek_frame(demuxer->fmt_ctx, -1, target_ts, AVSEEK_FLAG_BACKWARD);
    }

    SDL_LockMutex(demuxer->mutex);
    packet_queue_clear(&demuxer->video_queue);
    packet_queue_clear(&demuxer->audio_queue);
    demuxer->stop_requested = 0;
    demuxer->eof = 0;
    SDL_UnlockMutex(demuxer->mutex);

    if (seek_ret < 0) {
        return -1;
    }

    avformat_flush(demuxer->fmt_ctx);
    return demuxer_start(demuxer);
}

static int demuxer_pop_packet(Demuxer* demuxer, DemuxerPacketQueue* queue, SDL_Condition* can_read, AVPacket* out_packet) {
    if (!demuxer || !queue || !can_read || !out_packet || !demuxer->mutex) {
        return -1;
    }

    av_packet_unref(out_packet);

    SDL_LockMutex(demuxer->mutex);
    while (queue->count == 0 && !demuxer->eof && !demuxer->stop_requested && demuxer->thread_running) {
        SDL_WaitCondition(can_read, demuxer->mutex);
    }

    if (queue->count > 0) {
        packet_queue_pop(queue, out_packet);
        SDL_SignalCondition(demuxer->can_write);
        SDL_UnlockMutex(demuxer->mutex);
        return 1;
    }

    int stop_requested = demuxer->stop_requested;
    int eof = demuxer->eof;
    SDL_UnlockMutex(demuxer->mutex);

    if (stop_requested) {
        return -1;
    }
    if (eof) {
        return 0;
    }
    return -1;
}

int demuxer_pop_video_packet(Demuxer* demuxer, AVPacket* out_packet) {
    return demuxer_pop_packet(demuxer, &demuxer->video_queue, demuxer->can_read_video, out_packet);
}

int demuxer_pop_audio_packet(Demuxer* demuxer, AVPacket* out_packet) {
    if (!demuxer || demuxer->audio_stream_index < 0 || !demuxer->audio_stream) {
        return 0;
    }
    return demuxer_pop_packet(demuxer, &demuxer->audio_queue, demuxer->can_read_audio, out_packet);
}

int demuxer_is_eof(Demuxer* demuxer) {
    if (!demuxer || !demuxer->mutex) {
        return 1;
    }

    SDL_LockMutex(demuxer->mutex);
    int eof = demuxer->eof;
    SDL_UnlockMutex(demuxer->mutex);
    return eof;
}
