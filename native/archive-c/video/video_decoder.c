#include "video_decoder.h"
#include "player/demuxer.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int video_decoder_init(VideoDecoder* dec, AVStream* stream) {
    memset(dec, 0, sizeof(VideoDecoder));

    if (!stream || !stream->codecpar || stream->codecpar->codec_type != AVMEDIA_TYPE_VIDEO) {
        fprintf(stderr, "No valid video stream\n");
        return -1;
    }

    const AVCodec* codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) {
        fprintf(stderr, "Codec not found\n");
        return -1;
    }

    dec->codec_ctx = avcodec_alloc_context3(codec);
    if (!dec->codec_ctx) {
        fprintf(stderr, "Failed to allocate codec context\n");
        return -1;
    }

    if (avcodec_parameters_to_context(dec->codec_ctx, stream->codecpar) < 0) {
        fprintf(stderr, "Failed to copy codec parameters\n");
        goto fail;
    }

    if (avcodec_open2(dec->codec_ctx, codec, NULL) < 0) {
        fprintf(stderr, "Failed to open codec\n");
        goto fail;
    }

    dec->packet = av_packet_alloc();
    dec->frame = av_frame_alloc();
    if (!dec->packet || !dec->frame) {
        fprintf(stderr, "Failed to allocate packet/frame\n");
        goto fail;
    }

    dec->width = dec->codec_ctx->width;
    dec->height = dec->codec_ctx->height;
    dec->stream = stream;
    dec->pts = 0.0;
    dec->eof = 0;
    dec->sent_eof = 0;

    dec->sws_ctx = sws_getContext(
        dec->width, dec->height, dec->codec_ctx->pix_fmt,
        dec->width, dec->height, AV_PIX_FMT_RGBA,
        SWS_BILINEAR, NULL, NULL, NULL
    );
    if (!dec->sws_ctx) {
        fprintf(stderr, "Failed to create swscale context\n");
        goto fail;
    }

    int buffer_size = av_image_get_buffer_size(AV_PIX_FMT_RGBA, dec->width, dec->height, 1);
    if (buffer_size <= 0) {
        fprintf(stderr, "Failed to compute video buffer size\n");
        goto fail;
    }

    dec->buffer = av_malloc((size_t)buffer_size);
    if (!dec->buffer) {
        fprintf(stderr, "Failed to allocate video buffer\n");
        goto fail;
    }

    if (av_image_fill_arrays(dec->temp_data, dec->temp_linesize, dec->buffer, AV_PIX_FMT_RGBA, dec->width, dec->height, 1) < 0) {
        fprintf(stderr, "Failed to setup video buffer\n");
        goto fail;
    }

    printf("Video decoder: %dx%d\n", dec->width, dec->height);
    return 0;

fail:
    video_decoder_destroy(dec);
    return -1;
}

void video_decoder_destroy(VideoDecoder* dec) {
    if (dec->buffer) {
        av_free(dec->buffer);
        dec->buffer = NULL;
    }

    if (dec->sws_ctx) {
        sws_freeContext(dec->sws_ctx);
        dec->sws_ctx = NULL;
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
    dec->width = 0;
    dec->height = 0;
    dec->pts = 0.0;
    dec->eof = 0;
    dec->sent_eof = 0;
}

void video_decoder_flush(VideoDecoder* dec) {
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

int video_decoder_decode_frame(VideoDecoder* dec, struct Demuxer* demuxer) {
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
            } else {
                AVRational rate = dec->stream->avg_frame_rate;
                if (rate.num > 0 && rate.den > 0) {
                    dec->pts += av_q2d(av_inv_q(rate));
                } else {
                    dec->pts += (1.0 / 30.0);
                }
            }

            return 0;
        }

        if (ret == AVERROR(EAGAIN)) {
            if (dec->sent_eof) {
                dec->eof = 1;
                return -1;
            }

            int pop_result = demuxer_pop_video_packet(demuxer, dec->packet);
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

int video_decoder_get_image(VideoDecoder* dec, uint8_t** data, int* linesize) {
    if (!dec || !dec->sws_ctx || !dec->frame || !data || !linesize) {
        return -1;
    }

    int h = sws_scale(dec->sws_ctx, (const uint8_t* const*)dec->frame->data,
        dec->frame->linesize, 0, dec->height, &dec->temp_data[0], dec->temp_linesize);

    if (h <= 0) {
        return -1;
    }

    *data = dec->temp_data[0];
    *linesize = dec->temp_linesize[0];
    return 0;
}
