const std = @import("std");
const c = @cImport({
    @cInclude("video/video_decoder.h");
    @cInclude("player/demuxer.h");
});

pub export fn video_decoder_init(dec: ?*c.VideoDecoder, stream: ?*c.AVStream) c_int {
    if (dec == null) {
        return -1;
    }

    const d = dec.?;
    d.* = std.mem.zeroes(c.VideoDecoder);

    if (stream == null or stream.?.codecpar == null or stream.?.codecpar.*.codec_type != c.AVMEDIA_TYPE_VIDEO) {
        return -1;
    }

    const codec = c.avcodec_find_decoder(stream.?.codecpar.*.codec_id);
    if (codec == null) {
        return -1;
    }

    d.codec_ctx = c.avcodec_alloc_context3(codec);
    if (d.codec_ctx == null) {
        return -1;
    }

    if (c.avcodec_parameters_to_context(d.codec_ctx, stream.?.codecpar) < 0) {
        video_decoder_destroy(d);
        return -1;
    }

    if (c.avcodec_open2(d.codec_ctx, codec, null) < 0) {
        video_decoder_destroy(d);
        return -1;
    }

    d.packet = c.av_packet_alloc();
    d.frame = c.av_frame_alloc();
    if (d.packet == null or d.frame == null) {
        video_decoder_destroy(d);
        return -1;
    }

    d.width = d.codec_ctx.*.width;
    d.height = d.codec_ctx.*.height;
    d.stream = stream;
    d.pts = 0.0;
    d.eof = 0;
    d.sent_eof = 0;

    d.sws_ctx = c.sws_getContext(
        d.width,
        d.height,
        d.codec_ctx.*.pix_fmt,
        d.width,
        d.height,
        c.AV_PIX_FMT_RGBA,
        c.SWS_BILINEAR,
        null,
        null,
        null,
    );

    if (d.sws_ctx == null) {
        video_decoder_destroy(d);
        return -1;
    }

    const buffer_size = c.av_image_get_buffer_size(c.AV_PIX_FMT_RGBA, d.width, d.height, 1);
    if (buffer_size <= 0) {
        video_decoder_destroy(d);
        return -1;
    }

    d.buffer = @ptrCast(c.av_malloc(@intCast(buffer_size)));
    if (d.buffer == null) {
        video_decoder_destroy(d);
        return -1;
    }

    if (c.av_image_fill_arrays(&d.temp_data, &d.temp_linesize, d.buffer, c.AV_PIX_FMT_RGBA, d.width, d.height, 1) < 0) {
        video_decoder_destroy(d);
        return -1;
    }

    return 0;
}

pub export fn video_decoder_destroy(dec: ?*c.VideoDecoder) void {
    if (dec == null) {
        return;
    }

    const d = dec.?;

    if (d.buffer != null) {
        c.av_free(d.buffer);
        d.buffer = null;
    }

    if (d.sws_ctx != null) {
        c.sws_freeContext(d.sws_ctx);
        d.sws_ctx = null;
    }

    if (d.frame != null) {
        c.av_frame_free(&d.frame);
    }

    if (d.packet != null) {
        c.av_packet_free(&d.packet);
    }

    if (d.codec_ctx != null) {
        c.avcodec_free_context(&d.codec_ctx);
    }

    d.stream = null;
    d.width = 0;
    d.height = 0;
    d.pts = 0.0;
    d.eof = 0;
    d.sent_eof = 0;
}

pub export fn video_decoder_flush(dec: ?*c.VideoDecoder) void {
    if (dec == null or dec.?.codec_ctx == null) {
        return;
    }

    const d = dec.?;

    c.avcodec_flush_buffers(d.codec_ctx);

    if (d.packet != null) {
        c.av_packet_unref(d.packet);
    }

    if (d.frame != null) {
        c.av_frame_unref(d.frame);
    }

    d.eof = 0;
    d.sent_eof = 0;
}

pub export fn video_decoder_decode_frame(dec: ?*c.VideoDecoder, demuxer: ?*c.Demuxer) c_int {
    if (dec == null or demuxer == null) {
        return -1;
    }

    const d = dec.?;

    if (d.codec_ctx == null or d.frame == null or d.packet == null or d.stream == null) {
        return -1;
    }

    while (true) {
        var ret = c.avcodec_receive_frame(d.codec_ctx, d.frame);

        if (ret == 0) {
            var ts = d.frame.*.best_effort_timestamp;
            if (ts == c.AV_NOPTS_VALUE) {
                ts = d.frame.*.pts;
            }

            if (ts != c.AV_NOPTS_VALUE) {
                d.pts = @as(f64, @floatFromInt(ts)) * c.av_q2d(d.stream.*.time_base);
            } else {
                const rate = d.stream.*.avg_frame_rate;
                if (rate.num > 0 and rate.den > 0) {
                    d.pts += c.av_q2d(c.av_inv_q(rate));
                } else {
                    d.pts += 1.0 / 30.0;
                }
            }

            return 0;
        }

        if (ret == c.AVERROR(c.EAGAIN)) {
            if (d.sent_eof != 0) {
                d.eof = 1;
                return -1;
            }

            const pop_result = c.demuxer_pop_video_packet(demuxer, d.packet);
            if (pop_result > 0) {
                ret = c.avcodec_send_packet(d.codec_ctx, d.packet);
                c.av_packet_unref(d.packet);
                if (ret < 0 and ret != c.AVERROR(c.EAGAIN)) {
                    return -1;
                }
                continue;
            }

            if (pop_result == 0) {
                ret = c.avcodec_send_packet(d.codec_ctx, null);
                if (ret < 0 and ret != c.AVERROR_EOF) {
                    return -1;
                }
                d.sent_eof = 1;
                continue;
            }

            return -1;
        }

        if (ret == c.AVERROR_EOF) {
            d.eof = 1;
            return -1;
        }

        return -1;
    }
}

pub export fn video_decoder_get_image(dec: ?*c.VideoDecoder, data: [*c][*c]u8, linesize: [*c]c_int) c_int {
    if (dec == null or data == null or linesize == null) {
        return -1;
    }

    const d = dec.?;
    if (d.sws_ctx == null or d.frame == null) {
        return -1;
    }

    const h = c.sws_scale(
        d.sws_ctx,
        @ptrCast(&d.frame.*.data),
        @ptrCast(&d.frame.*.linesize),
        0,
        d.height,
        &d.temp_data,
        &d.temp_linesize,
    );

    if (h <= 0) {
        return -1;
    }

    data.* = d.temp_data[0];
    linesize.* = d.temp_linesize[0];
    return 0;
}
