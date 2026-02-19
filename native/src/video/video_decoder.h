#ifndef CPLAYER_VIDEO_DECODER_H
#define CPLAYER_VIDEO_DECODER_H

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <libavutil/imgutils.h>
#include <stdint.h>

struct Demuxer;

typedef struct {
    AVCodecContext* codec_ctx;
    AVStream* stream;
    struct SwsContext* sws_ctx;
    AVPacket* packet;
    AVFrame* frame;
    int width;
    int height;
    double pts;
    int eof;
    int sent_eof;
    uint8_t* temp_data[4];
    int temp_linesize[4];
    uint8_t* buffer;
} VideoDecoder;

int video_decoder_init(VideoDecoder* dec, AVStream* stream);
void video_decoder_destroy(VideoDecoder* dec);
void video_decoder_flush(VideoDecoder* dec);
int video_decoder_decode_frame(VideoDecoder* dec, struct Demuxer* demuxer);
int video_decoder_get_image(VideoDecoder* dec, uint8_t** data, int* linesize);

#endif
