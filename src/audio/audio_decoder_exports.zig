const std = @import("std");
const c = @cImport({
    @cInclude("audio/audio_decoder.h");
    @cInclude("player/demuxer.h");
    @cInclude("libavutil/channel_layout.h");
    @cInclude("libavutil/mem.h");
});

pub export fn audio_decoder_init(dec: ?*c.AudioDecoder, stream: ?*c.AVStream) c_int {
    if (dec == null) {
        return -1;
    }

    const d = dec.?;
    d.* = std.mem.zeroes(c.AudioDecoder);

    if (stream == null or stream.?.codecpar == null or stream.?.codecpar.*.codec_type != c.AVMEDIA_TYPE_AUDIO) {
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
        audio_decoder_destroy(d);
        return -1;
    }

    if (c.avcodec_open2(d.codec_ctx, codec, null) < 0) {
        audio_decoder_destroy(d);
        return -1;
    }

    d.sample_rate = d.codec_ctx.*.sample_rate;
    if (d.sample_rate <= 0) {
        d.sample_rate = 48000;
    }

    d.packet = c.av_packet_alloc();
    d.frame = c.av_frame_alloc();
    if (d.packet == null or d.frame == null) {
        audio_decoder_destroy(d);
        return -1;
    }

    d.swr_ctx = c.swr_alloc();
    if (d.swr_ctx == null) {
        audio_decoder_destroy(d);
        return -1;
    }

    var in_layout = std.mem.zeroes(c.AVChannelLayout);
    var out_layout = std.mem.zeroes(c.AVChannelLayout);

    if (c.av_channel_layout_copy(&in_layout, &d.codec_ctx.*.ch_layout) < 0 or in_layout.nb_channels <= 0 or c.av_channel_layout_check(&in_layout) == 0) {
        c.av_channel_layout_uninit(&in_layout);
        c.av_channel_layout_default(&in_layout, 2);
    }

    c.av_channel_layout_default(&out_layout, in_layout.nb_channels);
    d.channels = out_layout.nb_channels;

    if (d.channels <= 0) {
        d.channels = 2;
        c.av_channel_layout_uninit(&out_layout);
        c.av_channel_layout_default(&out_layout, d.channels);
    }

    d.channel_layout = if (d.channels == 1) c.AV_CH_LAYOUT_MONO else c.AV_CH_LAYOUT_STEREO;

    if (c.swr_alloc_set_opts2(
        &d.swr_ctx,
        &out_layout,
        c.AV_SAMPLE_FMT_FLT,
        d.sample_rate,
        &in_layout,
        d.codec_ctx.*.sample_fmt,
        d.sample_rate,
        0,
        null,
    ) < 0) {
        c.av_channel_layout_uninit(&out_layout);
        c.av_channel_layout_uninit(&in_layout);
        audio_decoder_destroy(d);
        return -1;
    }

    c.av_channel_layout_uninit(&out_layout);
    c.av_channel_layout_uninit(&in_layout);

    if (c.swr_init(d.swr_ctx) < 0) {
        audio_decoder_destroy(d);
        return -1;
    }

    d.stream = stream;
    d.pts = 0.0;
    d.eof = 0;
    d.sent_eof = 0;

    return 0;
}

pub export fn audio_decoder_destroy(dec: ?*c.AudioDecoder) void {
    if (dec == null) {
        return;
    }

    const d = dec.?;

    if (d.output_buffer != null) {
        c.av_free(d.output_buffer);
        d.output_buffer = null;
        d.output_buffer_size = 0;
    }

    if (d.swr_ctx != null) {
        c.swr_free(&d.swr_ctx);
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
    d.sample_rate = 0;
    d.channels = 0;
    d.channel_layout = 0;
    d.pts = 0.0;
    d.eof = 0;
    d.sent_eof = 0;
}

pub export fn audio_decoder_flush(dec: ?*c.AudioDecoder) void {
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

pub export fn audio_decoder_decode_frame(dec: ?*c.AudioDecoder, demuxer: ?*c.Demuxer) c_int {
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
            }

            return 0;
        }

        if (ret == c.AVERROR(c.EAGAIN)) {
            if (d.sent_eof != 0) {
                d.eof = 1;
                return -1;
            }

            const pop_result = c.demuxer_pop_audio_packet(demuxer, d.packet);
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

pub export fn audio_decoder_get_samples(dec: ?*c.AudioDecoder, data: [*c][*c]u8, nb_samples: [*c]c_int) c_int {
    if (dec == null or data == null or nb_samples == null) {
        return -1;
    }

    const d = dec.?;

    if (d.frame == null or d.swr_ctx == null or d.frame.*.nb_samples <= 0) {
        return -1;
    }

    const out_samples = c.swr_get_out_samples(d.swr_ctx, d.frame.*.nb_samples);
    if (out_samples <= 0) {
        return -1;
    }

    const out_buffer_size = c.av_samples_get_buffer_size(null, d.channels, out_samples, c.AV_SAMPLE_FMT_FLT, 0);
    if (out_buffer_size <= 0) {
        return -1;
    }

    if (d.output_buffer_size < out_buffer_size) {
        const new_buffer = c.av_realloc(d.output_buffer, @intCast(out_buffer_size));
        if (new_buffer == null) {
            return -1;
        }

        d.output_buffer = @ptrCast(new_buffer);
        d.output_buffer_size = out_buffer_size;
    }

    var output_planes: [1][*c]u8 = .{d.output_buffer};
    const converted_samples = c.swr_convert(
        d.swr_ctx,
        &output_planes,
        out_samples,
        @ptrCast(&d.frame.*.data),
        d.frame.*.nb_samples,
    );

    if (converted_samples <= 0) {
        return -1;
    }

    data.* = d.output_buffer;
    nb_samples.* = converted_samples;
    return 0;
}
