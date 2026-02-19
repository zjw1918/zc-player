#ifndef CPLAYER_DEMUXER_H
#define CPLAYER_DEMUXER_H

#include <SDL3/SDL.h>
#include <libavformat/avformat.h>
#include <libavcodec/packet.h>

#define DEMUXER_PACKET_QUEUE_CAPACITY 256

typedef struct {
    AVPacket* packets[DEMUXER_PACKET_QUEUE_CAPACITY];
    int head;
    int tail;
    int count;
} DemuxerPacketQueue;

typedef struct Demuxer {
    AVFormatContext* fmt_ctx;
    int video_stream_index;
    int audio_stream_index;
    AVStream* video_stream;
    AVStream* audio_stream;

    DemuxerPacketQueue video_queue;
    DemuxerPacketQueue audio_queue;

    SDL_Mutex* mutex;
    SDL_Condition* can_read_video;
    SDL_Condition* can_read_audio;
    SDL_Condition* can_write;

    SDL_Thread* thread;
    int thread_running;
    int stop_requested;
    int eof;
} Demuxer;

int demuxer_open(Demuxer* demuxer, const char* filepath);
int demuxer_start(Demuxer* demuxer);
void demuxer_stop(Demuxer* demuxer);
void demuxer_close(Demuxer* demuxer);
int demuxer_seek(Demuxer* demuxer, double time_seconds);
int demuxer_pop_video_packet(Demuxer* demuxer, AVPacket* out_packet);
int demuxer_pop_audio_packet(Demuxer* demuxer, AVPacket* out_packet);
int demuxer_is_eof(Demuxer* demuxer);

#endif
