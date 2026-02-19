#include "audio_decoder.h"
#include "player/demuxer.h"
#include <libavutil/channel_layout.h>
#include <libavutil/mem.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int audio_decoder_init(AudioDecoder* dec, AVStream* stream) {
    memset(dec, 0, sizeof(AudioDecoder));

    if (!stream || !stream->codecpar || stream->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
        fprintf(stderr, "No valid audio stream\n");
        return -1;
    }

    const AVCodec* codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) {
        fprintf(stderr, "Audio codec not found\n");
        return -1;
    }

    dec->codec_ctx = avcodec_alloc_context3(codec);
    if (!dec->codec_ctx) {
        fprintf(stderr, "Failed to allocate audio codec context\n");
        return -1;
    }

    if (avcodec_parameters_to_context(dec->codec_ctx, stream->codecpar) < 0) {
        fprintf(stderr, "Failed to copy audio codec parameters\n");
        goto fail;
    }

    if (avcodec_open2(dec->codec_ctx, codec, NULL) < 0) {
        fprintf(stderr, "Failed to open audio codec\n");
        goto fail;
    }

    dec->sample_rate = dec->codec_ctx->sample_rate;
    if (dec->sample_rate <= 0) {
        dec->sample_rate = 48000;
    }

    dec->packet = av_packet_alloc();
    dec->frame = av_frame_alloc();
    if (!dec->packet || !dec->frame) {
        fprintf(stderr, "Failed to allocate audio packet/frame\n");
        goto fail;
    }

    dec->swr_ctx = swr_alloc();
    if (!dec->swr_ctx) {
        fprintf(stderr, "Failed to allocate swr context\n");
        goto fail;
    }

    AVChannelLayout in_layout;
    AVChannelLayout out_layout;
    memset(&in_layout, 0, sizeof(in_layout));
    memset(&out_layout, 0, sizeof(out_layout));

    if (av_channel_layout_copy(&in_layout, &dec->codec_ctx->ch_layout) < 0 || in_layout.nb_channels <= 0 || !av_channel_layout_check(&in_layout)) {
        av_channel_layout_uninit(&in_layout);
        av_channel_layout_default(&in_layout, 2);
    }

    av_channel_layout_default(&out_layout, in_layout.nb_channels);
    dec->channels = out_layout.nb_channels;
    if (dec->channels <= 0) {
        dec->channels = 2;
        av_channel_layout_uninit(&out_layout);
        av_channel_layout_default(&out_layout, dec->channels);
    }

    dec->channel_layout = (dec->channels == 1) ? AV_CH_LAYOUT_MONO : AV_CH_LAYOUT_STEREO;

    if (swr_alloc_set_opts2(
            &dec->swr_ctx,
            &out_layout,
            AV_SAMPLE_FMT_FLT,
            dec->sample_rate,
            &in_layout,
            dec->codec_ctx->sample_fmt,
            dec->sample_rate,
            0,
            NULL) < 0) {
        av_channel_layout_uninit(&out_layout);
        av_channel_layout_uninit(&in_layout);
        fprintf(stderr, "Failed to configure swr context\n");
        goto fail;
    }

    av_channel_layout_uninit(&out_layout);
    av_channel_layout_uninit(&in_layout);

    if (swr_init(dec->swr_ctx) < 0) {
        fprintf(stderr, "Failed to init swr context\n");
        goto fail;
    }

    dec->stream = stream;
    dec->pts = 0.0;
    dec->eof = 0;
    dec->sent_eof = 0;

    printf("Audio decoder: %d channels, %d Hz\n", dec->channels, dec->sample_rate);
    return 0;

fail:
    audio_decoder_destroy(dec);
    return -1;
}

void audio_decoder_destroy(AudioDecoder* dec) {
    if (dec->output_buffer) {
        av_free(dec->output_buffer);
        dec->output_buffer = NULL;
        dec->output_buffer_size = 0;
    }

    if (dec->swr_ctx) {
        swr_free(&dec->swr_ctx);
    }

    if (dec->frame) {
        av_frame_free(&dec->frame);
    }

    if (dec->packet) {
        av_packet_free(&dec->packet);
    }

    if (dec->codec_ctx) {
        avcodec_free_context(&dec->codec_ctx);
    }

    dec->stream = NULL;
    dec->sample_rate = 0;
    dec->channels = 0;
    dec->channel_layout = 0;
    dec->pts = 0.0;
    dec->eof = 0;
    dec->sent_eof = 0;
}

void audio_decoder_flush(AudioDecoder* dec) {
    if (!dec || !dec->codec_ctx) {
        return;
    }

    avcodec_flush_buffers(dec->codec_ctx);
    if (dec->packet) {
        av_packet_unref(dec->packet);
    }
    if (dec->frame) {
        av_frame_unref(dec->frame);
    }
    dec->eof = 0;
    dec->sent_eof = 0;
}

int audio_decoder_decode_frame(AudioDecoder* dec, struct Demuxer* demuxer) {
    if (!dec || !dec->codec_ctx || !dec->frame || !dec->packet || !dec->stream || !demuxer) {
        return -1;
    }

    while (1) {
        int ret = avcodec_receive_frame(dec->codec_ctx, dec->frame);
        if (ret == 0) {
            int64_t ts = dec->frame->best_effort_timestamp;
            if (ts == AV_NOPTS_VALUE) {
                ts = dec->frame->pts;
            }

            if (ts != AV_NOPTS_VALUE) {
                dec->pts = (double)ts * av_q2d(dec->stream->time_base);
            }

            return 0;
        }

        if (ret == AVERROR(EAGAIN)) {
            if (dec->sent_eof) {
                dec->eof = 1;
                return -1;
            }

            int pop_result = demuxer_pop_audio_packet(demuxer, dec->packet);
            if (pop_result > 0) {
                ret = avcodec_send_packet(dec->codec_ctx, dec->packet);
                av_packet_unref(dec->packet);
                if (ret < 0 && ret != AVERROR(EAGAIN)) {
                    return -1;
                }
                continue;
            }

            if (pop_result == 0) {
                ret = avcodec_send_packet(dec->codec_ctx, NULL);
                if (ret < 0 && ret != AVERROR_EOF) {
                    return -1;
                }
                dec->sent_eof = 1;
                continue;
            }

            return -1;
        }

        if (ret == AVERROR_EOF) {
            dec->eof = 1;
            return -1;
        }

        return -1;
    }
}

int audio_decoder_get_samples(AudioDecoder* dec, uint8_t** data, int* nb_samples) {
    if (!dec || !dec->frame || !dec->swr_ctx || !data || !nb_samples || dec->frame->nb_samples <= 0) {
        return -1;
    }

    int out_samples = swr_get_out_samples(dec->swr_ctx, dec->frame->nb_samples);
    if (out_samples <= 0) {
        return -1;
    }

    int out_buffer_size = av_samples_get_buffer_size(NULL, dec->channels, out_samples, AV_SAMPLE_FMT_FLT, 0);
    if (out_buffer_size <= 0) {
        return -1;
    }

    if (dec->output_buffer_size < out_buffer_size) {
        uint8_t* new_buffer = av_realloc(dec->output_buffer, out_buffer_size);
        if (!new_buffer) {
            return -1;
        }
        dec->output_buffer = new_buffer;
        dec->output_buffer_size = out_buffer_size;
    }

    uint8_t* output_planes[1] = {dec->output_buffer};
    int converted_samples = swr_convert(dec->swr_ctx, output_planes, out_samples,
        (const uint8_t**)dec->frame->data, dec->frame->nb_samples);

    if (converted_samples <= 0) {
        return -1;
    }

    *data = dec->output_buffer;
    *nb_samples = converted_samples;
    return 0;
}
