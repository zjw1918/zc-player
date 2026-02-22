#ifndef CPLAYER_VIDEO_DECODER_H
#define CPLAYER_VIDEO_DECODER_H

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <libavutil/imgutils.h>
#include <libavutil/hwcontext.h>
#include <stdint.h>

struct Demuxer;

typedef struct {
    AVCodecContext* codec_ctx;
    AVStream* stream;
    struct SwsContext* sws_ctx;
    AVPacket* packet;
    AVFrame* frame;
    AVFrame* sw_frame;
    int width;
    int height;
    double pts;
    int eof;
    int sent_eof;
    enum AVPixelFormat sws_src_fmt;
    enum AVPixelFormat hw_pix_fmt;
    int hw_enabled;
    uint8_t* temp_data[4];
    int temp_linesize[4];
    uint8_t* buffer;
    int buffer_size;
} VideoDecoder;

typedef enum {
    VIDEO_FRAME_FORMAT_RGBA = 0,
    VIDEO_FRAME_FORMAT_YUV420P = 1,
    VIDEO_FRAME_FORMAT_NV12 = 2,
} VideoFrameFormat;

int video_decoder_init(VideoDecoder* dec, AVStream* stream);
void video_decoder_destroy(VideoDecoder* dec);
void video_decoder_flush(VideoDecoder* dec);
int video_decoder_decode_frame(VideoDecoder* dec, struct Demuxer* demuxer);
int video_decoder_get_image(VideoDecoder* dec, uint8_t** data, int* linesize);
int video_decoder_get_format(VideoDecoder* dec);

#endif
