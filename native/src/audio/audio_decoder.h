#ifndef CPLAYER_AUDIO_DECODER_H
#define CPLAYER_AUDIO_DECODER_H

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>

struct Demuxer;

typedef struct {
    AVCodecContext* codec_ctx;
    AVStream* stream;
    struct SwrContext* swr_ctx;
    AVPacket* packet;
    AVFrame* frame;
    int sample_rate;
    int channels;
    int64_t channel_layout;
    double pts;
    int eof;
    int sent_eof;
    uint8_t* output_buffer;
    int output_buffer_size;
} AudioDecoder;

int audio_decoder_init(AudioDecoder* dec, AVStream* stream);
void audio_decoder_destroy(AudioDecoder* dec);
void audio_decoder_flush(AudioDecoder* dec);
int audio_decoder_decode_frame(AudioDecoder* dec, struct Demuxer* demuxer);
int audio_decoder_get_samples(AudioDecoder* dec, uint8_t** data, int* nb_samples);

#endif
