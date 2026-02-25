const builtin = @import("builtin");
const std = @import("std");
const c = @cImport({
    @cInclude("video/video_decoder.h");
    @cInclude("player/demuxer.h");
});

fn hwDecodeDebugEnabled() bool {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, "ZC_DEBUG_HW_DECODE") catch return false;
    defer std.heap.page_allocator.free(value);

    return value.len > 0 and value[0] != '0';
}

const HwDecodePolicy = enum {
    auto,
    off,
    d3d11va,
    dxva2,
    videotoolbox,
};

fn parseHwDecodePolicy(value: []const u8) HwDecodePolicy {
    if (std.ascii.eqlIgnoreCase(value, "off") or std.ascii.eqlIgnoreCase(value, "none") or std.ascii.eqlIgnoreCase(value, "0")) {
        return .off;
    }
    if (std.ascii.eqlIgnoreCase(value, "d3d11") or std.ascii.eqlIgnoreCase(value, "d3d11va")) {
        return .d3d11va;
    }
    if (std.ascii.eqlIgnoreCase(value, "dxva2")) {
        return .dxva2;
    }
    if (std.ascii.eqlIgnoreCase(value, "videotoolbox") or std.ascii.eqlIgnoreCase(value, "vt")) {
        return .videotoolbox;
    }
    return .auto;
}

fn hwDecodePolicyFromEnvironment() HwDecodePolicy {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, "ZC_HW_DECODE") catch return .auto;
    defer std.heap.page_allocator.free(value);
    return parseHwDecodePolicy(value);
}

fn hwDeviceLabel(device_type: c.AVHWDeviceType) []const u8 {
    return switch (device_type) {
        c.AV_HWDEVICE_TYPE_VIDEOTOOLBOX => "videotoolbox",
        c.AV_HWDEVICE_TYPE_D3D11VA => "d3d11va",
        c.AV_HWDEVICE_TYPE_DXVA2 => "dxva2",
        else => "none",
    };
}

fn hwBackendTag(device_type: c.AVHWDeviceType) c_int {
    return switch (device_type) {
        c.AV_HWDEVICE_TYPE_VIDEOTOOLBOX => c.VIDEO_HW_BACKEND_VIDEOTOOLBOX,
        c.AV_HWDEVICE_TYPE_D3D11VA => c.VIDEO_HW_BACKEND_D3D11VA,
        c.AV_HWDEVICE_TYPE_DXVA2 => c.VIDEO_HW_BACKEND_DXVA2,
        else => c.VIDEO_HW_BACKEND_NONE,
    };
}

fn hwPolicyLabel(policy: HwDecodePolicy) []const u8 {
    return switch (policy) {
        .auto => "auto",
        .off => "off",
        .d3d11va => "d3d11va",
        .dxva2 => "dxva2",
        .videotoolbox => "videotoolbox",
    };
}

fn hwPolicyTag(policy: HwDecodePolicy) c_int {
    return switch (policy) {
        .auto => c.VIDEO_HW_POLICY_AUTO,
        .off => c.VIDEO_HW_POLICY_OFF,
        .d3d11va => c.VIDEO_HW_POLICY_D3D11VA,
        .dxva2 => c.VIDEO_HW_POLICY_DXVA2,
        .videotoolbox => c.VIDEO_HW_POLICY_VIDEOTOOLBOX,
    };
}

fn shouldTryHardware(codec_ctx: ?*c.AVCodecContext) bool {
    if (codec_ctx == null) {
        return false;
    }

    const codec_id = codec_ctx.?.codec_id;
    if (codec_id != c.AV_CODEC_ID_H264 and codec_id != c.AV_CODEC_ID_HEVC) {
        return false;
    }

    return switch (builtin.os.tag) {
        .macos => c.av_hwdevice_find_type_by_name("videotoolbox") != c.AV_HWDEVICE_TYPE_NONE,
        .windows => c.av_hwdevice_find_type_by_name("d3d11va") != c.AV_HWDEVICE_TYPE_NONE or c.av_hwdevice_find_type_by_name("dxva2") != c.AV_HWDEVICE_TYPE_NONE,
        else => false,
    };
}

fn chooseOutputPixelFormat(preferred: c.AVPixelFormat, pix_fmts: [*c]const c.AVPixelFormat) c.AVPixelFormat {
    var i: usize = 0;
    while (pix_fmts[i] != c.AV_PIX_FMT_NONE) : (i += 1) {
        if (preferred != c.AV_PIX_FMT_NONE and pix_fmts[i] == preferred) {
            return preferred;
        }
    }

    return pix_fmts[0];
}

fn selectHardwarePixelFormat(codec: ?*const c.AVCodec, device_type: c.AVHWDeviceType) c.AVPixelFormat {
    if (codec == null) {
        return c.AV_PIX_FMT_NONE;
    }

    var i: c_int = 0;
    while (true) : (i += 1) {
        const config = c.avcodec_get_hw_config(codec, i);
        if (config == null) {
            break;
        }

        if ((config.?.*.methods & c.AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) != 0 and
            config.?.*.device_type == device_type)
        {
            return config.?.*.pix_fmt;
        }
    }

    return c.AV_PIX_FMT_NONE;
}

fn decoderGetFormat(codec_ctx: ?*c.AVCodecContext, pix_fmts: [*c]const c.AVPixelFormat) callconv(.c) c.AVPixelFormat {
    if (codec_ctx == null or pix_fmts == null) {
        return c.AV_PIX_FMT_NONE;
    }

    const ctx = codec_ctx.?;
    if (ctx.*.@"opaque" != null) {
        const decoder: *c.VideoDecoder = @ptrCast(@alignCast(ctx.*.@"opaque"));
        return chooseOutputPixelFormat(decoder.hw_pix_fmt, pix_fmts);
    }

    return chooseOutputPixelFormat(c.AV_PIX_FMT_NONE, pix_fmts);
}

fn disableHardwareDecode(decoder: *c.VideoDecoder) void {
    decoder.hw_enabled = 0;
    decoder.hw_pix_fmt = c.AV_PIX_FMT_NONE;
    decoder.hw_device_type = c.AV_HWDEVICE_TYPE_NONE;

    const codec_ctx = decoder.codec_ctx orelse return;

    if (codec_ctx.*.hw_device_ctx != null) {
        c.av_buffer_unref(&codec_ctx.*.hw_device_ctx);
    }

    codec_ctx.*.get_format = c.avcodec_default_get_format;
    codec_ctx.*.@"opaque" = null;
}

fn clearHardwareFrameRef(decoder: *c.VideoDecoder) void {
    if (decoder.hw_frame_ref != null) {
        c.av_frame_free(&decoder.hw_frame_ref);
    }
}

fn refreshHardwareFrameRef(decoder: *c.VideoDecoder) c_int {
    if (decoder.frame == null) {
        return -1;
    }

    if (decoder.hw_frame_ref == null) {
        decoder.hw_frame_ref = c.av_frame_alloc();
    }

    if (decoder.hw_frame_ref == null) {
        return -1;
    }

    c.av_frame_unref(decoder.hw_frame_ref);
    if (c.av_frame_ref(decoder.hw_frame_ref, decoder.frame) < 0) {
        return -1;
    }

    return 0;
}

fn configureHardwareDecode(decoder: *c.VideoDecoder, codec: ?*const c.AVCodec) void {
    disableHardwareDecode(decoder);

    const codec_ctx = decoder.codec_ctx orelse return;

    const policy = hwDecodePolicyFromEnvironment();
    if (policy == .off) {
        return;
    }

    if (!shouldTryHardware(codec_ctx)) {
        return;
    }

    if (builtin.os.tag == .macos) {
        if ((policy == .auto or policy == .videotoolbox) and tryEnableHardwareDevice(decoder, codec_ctx, codec, c.AV_HWDEVICE_TYPE_VIDEOTOOLBOX)) {
            return;
        }
        return;
    }

    if (builtin.os.tag == .windows) {
        if (policy == .auto or policy == .d3d11va) {
            if (tryEnableHardwareDevice(decoder, codec_ctx, codec, c.AV_HWDEVICE_TYPE_D3D11VA)) {
                return;
            }
        }

        if (policy == .auto or policy == .dxva2) {
            _ = tryEnableHardwareDevice(decoder, codec_ctx, codec, c.AV_HWDEVICE_TYPE_DXVA2);
        }
    }
}

fn tryEnableHardwareDevice(
    decoder: *c.VideoDecoder,
    codec_ctx: *c.AVCodecContext,
    codec: ?*const c.AVCodec,
    device_type: c.AVHWDeviceType,
) bool {
    const hw_pix_fmt = selectHardwarePixelFormat(codec, device_type);
    if (hw_pix_fmt == c.AV_PIX_FMT_NONE) {
        return false;
    }

    var hw_device_ctx: ?*c.AVBufferRef = null;
    if (c.av_hwdevice_ctx_create(&hw_device_ctx, device_type, null, null, 0) < 0 or hw_device_ctx == null) {
        return false;
    }

    codec_ctx.*.hw_device_ctx = c.av_buffer_ref(hw_device_ctx);
    c.av_buffer_unref(&hw_device_ctx);

    if (codec_ctx.*.hw_device_ctx == null) {
        return false;
    }

    codec_ctx.*.@"opaque" = decoder;
    codec_ctx.*.get_format = decoderGetFormat;
    decoder.hw_pix_fmt = hw_pix_fmt;
    decoder.hw_device_type = device_type;
    decoder.hw_enabled = 1;
    return true;
}

fn ensureRgbaBuffer(decoder: *c.VideoDecoder, width: c_int, height: c_int) c_int {
    const required_size = c.av_image_get_buffer_size(c.AV_PIX_FMT_RGBA, width, height, 1);
    if (required_size <= 0) {
        return -1;
    }

    if (decoder.buffer == null or decoder.buffer_size < required_size) {
        const new_buffer = if (decoder.buffer == null)
            c.av_malloc(@intCast(required_size))
        else
            c.av_realloc(decoder.buffer, @intCast(required_size));

        if (new_buffer == null) {
            return -1;
        }

        decoder.buffer = @ptrCast(new_buffer);
        decoder.buffer_size = required_size;
    }

    if (c.av_image_fill_arrays(
        &decoder.temp_data,
        &decoder.temp_linesize,
        decoder.buffer,
        c.AV_PIX_FMT_RGBA,
        width,
        height,
        1,
    ) < 0) {
        return -1;
    }

    return 0;
}

fn ensureScaleContext(decoder: *c.VideoDecoder, src_frame: *c.AVFrame) c_int {
    if (src_frame.*.width <= 0 or src_frame.*.height <= 0) {
        return -1;
    }

    const src_fmt: c.AVPixelFormat = src_frame.*.format;
    const dimensions_changed = decoder.width != src_frame.*.width or decoder.height != src_frame.*.height;
    const format_changed = decoder.sws_src_fmt != src_fmt;

    if (decoder.sws_ctx == null or dimensions_changed or format_changed) {
        if (decoder.sws_ctx != null) {
            c.sws_freeContext(decoder.sws_ctx);
            decoder.sws_ctx = null;
        }

        decoder.sws_ctx = c.sws_getContext(
            src_frame.*.width,
            src_frame.*.height,
            src_fmt,
            src_frame.*.width,
            src_frame.*.height,
            c.AV_PIX_FMT_RGBA,
            c.SWS_FAST_BILINEAR,
            null,
            null,
            null,
        );
        if (decoder.sws_ctx == null) {
            return -1;
        }

        decoder.sws_src_fmt = src_fmt;
        decoder.width = src_frame.*.width;
        decoder.height = src_frame.*.height;
    }

    return ensureRgbaBuffer(decoder, src_frame.*.width, src_frame.*.height);
}

fn sourceFrameForScale(decoder: *c.VideoDecoder) ?*c.AVFrame {
    if (decoder.frame == null) {
        return null;
    }

    if (decoder.hw_enabled != 0 and decoder.frame.?.*.format == decoder.hw_pix_fmt) {
        if (decoder.sw_frame == null) {
            return null;
        }

        c.av_frame_unref(decoder.sw_frame);
        if (c.av_hwframe_transfer_data(decoder.sw_frame, decoder.frame, 0) < 0) {
            return null;
        }

        _ = c.av_frame_copy_props(decoder.sw_frame, decoder.frame);
        return decoder.sw_frame;
    }

    return decoder.frame;
}

fn decodeFormatTag(pix_fmt: c.AVPixelFormat) c_int {
    return switch (pix_fmt) {
        c.AV_PIX_FMT_YUV420P => c.VIDEO_FRAME_FORMAT_YUV420P,
        c.AV_PIX_FMT_NV12 => c.VIDEO_FRAME_FORMAT_NV12,
        c.AV_PIX_FMT_VIDEOTOOLBOX => c.VIDEO_FRAME_FORMAT_NV12,
        c.AV_PIX_FMT_D3D11 => c.VIDEO_FRAME_FORMAT_NV12,
        c.AV_PIX_FMT_DXVA2_VLD => c.VIDEO_FRAME_FORMAT_NV12,
        else => c.VIDEO_FRAME_FORMAT_RGBA,
    };
}

fn planeCountForFormatTag(format: c_int) c_int {
    return switch (format) {
        c.VIDEO_FRAME_FORMAT_YUV420P => 3,
        c.VIDEO_FRAME_FORMAT_NV12 => 2,
        else => 1,
    };
}

pub export fn video_decoder_init(dec: ?*c.VideoDecoder, stream: ?*c.AVStream) c_int {
    if (dec == null) {
        return -1;
    }

    const d = dec.?;
    d.* = std.mem.zeroes(c.VideoDecoder);
    d.sws_src_fmt = c.AV_PIX_FMT_NONE;
    d.hw_pix_fmt = c.AV_PIX_FMT_NONE;

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

    configureHardwareDecode(d, codec);

    if (c.avcodec_open2(d.codec_ctx, codec, null) < 0) {
        if (d.hw_enabled != 0) {
            disableHardwareDecode(d);
            if (c.avcodec_open2(d.codec_ctx, codec, null) < 0) {
                video_decoder_destroy(d);
                return -1;
            }
        } else {
            video_decoder_destroy(d);
            return -1;
        }
    }

    d.packet = c.av_packet_alloc();
    d.frame = c.av_frame_alloc();
    d.sw_frame = c.av_frame_alloc();
    if (d.packet == null or d.frame == null or d.sw_frame == null) {
        video_decoder_destroy(d);
        return -1;
    }

    d.width = d.codec_ctx.*.width;
    d.height = d.codec_ctx.*.height;
    d.stream = stream;
    d.pts = 0.0;
    d.eof = 0;
    d.sent_eof = 0;

    if (d.width > 0 and d.height > 0 and ensureRgbaBuffer(d, d.width, d.height) != 0) {
        video_decoder_destroy(d);
        return -1;
    }

    if (hwDecodeDebugEnabled()) {
        std.debug.print(
            "video_decoder_init: hw_enabled={} policy={s} backend={s} hw_pix_fmt={} codec_id={}\n",
            .{ d.hw_enabled, hwPolicyLabel(hwDecodePolicyFromEnvironment()), hwDeviceLabel(d.hw_device_type), @as(c_int, d.hw_pix_fmt), @as(c_uint, d.codec_ctx.*.codec_id) },
        );
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
        d.buffer_size = 0;
    }

    if (d.sws_ctx != null) {
        c.sws_freeContext(d.sws_ctx);
        d.sws_ctx = null;
    }

    if (d.sw_frame != null) {
        c.av_frame_free(&d.sw_frame);
    }

    clearHardwareFrameRef(d);

    if (d.frame != null) {
        c.av_frame_free(&d.frame);
    }

    if (d.packet != null) {
        c.av_packet_free(&d.packet);
    }

    disableHardwareDecode(d);

    if (d.codec_ctx != null) {
        c.avcodec_free_context(&d.codec_ctx);
    }

    d.stream = null;
    d.width = 0;
    d.height = 0;
    d.pts = 0.0;
    d.eof = 0;
    d.sent_eof = 0;
    d.sws_src_fmt = c.AV_PIX_FMT_NONE;
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

    if (d.sw_frame != null) {
        c.av_frame_unref(d.sw_frame);
    }

    clearHardwareFrameRef(d);

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
            if (d.hw_enabled != 0 and d.frame.*.format == d.hw_pix_fmt) {
                if (refreshHardwareFrameRef(d) != 0) {
                    return -1;
                }
            } else {
                clearHardwareFrameRef(d);
            }

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
    const src_frame = sourceFrameForScale(d) orelse return -1;

    if (ensureScaleContext(d, src_frame) != 0) {
        return -1;
    }

    const h = c.sws_scale(
        d.sws_ctx,
        @ptrCast(&src_frame.*.data),
        @ptrCast(&src_frame.*.linesize),
        0,
        src_frame.*.height,
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

pub export fn video_decoder_get_format(dec: ?*c.VideoDecoder) c_int {
    if (dec == null) {
        return c.VIDEO_FRAME_FORMAT_RGBA;
    }

    if (dec.?.frame == null) {
        return c.VIDEO_FRAME_FORMAT_RGBA;
    }

    const pix_fmt: c.AVPixelFormat = dec.?.frame.*.format;
    return decodeFormatTag(pix_fmt);
}

pub export fn video_decoder_is_hw_enabled(dec: ?*c.VideoDecoder) c_int {
    if (dec == null) {
        return 0;
    }

    return dec.?.hw_enabled;
}

pub export fn video_decoder_get_hw_backend(dec: ?*c.VideoDecoder) c_int {
    if (dec == null) {
        return c.VIDEO_HW_BACKEND_NONE;
    }

    return hwBackendTag(dec.?.hw_device_type);
}

pub export fn video_decoder_get_hw_policy() c_int {
    return hwPolicyTag(hwDecodePolicyFromEnvironment());
}

pub export fn video_decoder_get_hw_frame_token(dec: ?*c.VideoDecoder) u64 {
    if (dec == null) {
        return 0;
    }

    const d = dec.?;
    if (d.hw_enabled == 0 or d.hw_frame_ref == null) {
        return 0;
    }

    return @intFromPtr(d.hw_frame_ref);
}

pub export fn video_decoder_get_planes(
    dec: ?*c.VideoDecoder,
    planes: [*c][*c]u8,
    linesizes: [*c]c_int,
    plane_count: [*c]c_int,
) c_int {
    if (dec == null or planes == null or linesizes == null or plane_count == null) {
        return -1;
    }

    const d = dec.?;
    const src_frame = sourceFrameForScale(d) orelse return -1;
    const format = decodeFormatTag(src_frame.*.format);

    if (format == c.VIDEO_FRAME_FORMAT_RGBA) {
        var data0: [*c]u8 = null;
        var linesize0: c_int = 0;
        if (video_decoder_get_image(dec, &data0, &linesize0) != 0) {
            return -1;
        }

        planes[0] = data0;
        linesizes[0] = linesize0;
        plane_count.* = 1;
        return 0;
    }

    const count = planeCountForFormatTag(format);
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        const idx: usize = @intCast(i);
        planes[idx] = src_frame.*.data[idx];
        linesizes[idx] = src_frame.*.linesize[idx];
    }

    plane_count.* = count;
    return 0;
}

test "chooseOutputPixelFormat prefers requested format" {
    const formats = [_]c.AVPixelFormat{
        c.AV_PIX_FMT_YUV420P,
        c.AV_PIX_FMT_NV12,
        c.AV_PIX_FMT_NONE,
    };

    try std.testing.expectEqual(c.AV_PIX_FMT_NV12, chooseOutputPixelFormat(c.AV_PIX_FMT_NV12, &formats));
}

test "chooseOutputPixelFormat falls back to first offered format" {
    const formats = [_]c.AVPixelFormat{
        c.AV_PIX_FMT_YUV420P,
        c.AV_PIX_FMT_NV12,
        c.AV_PIX_FMT_NONE,
    };

    try std.testing.expectEqual(c.AV_PIX_FMT_YUV420P, chooseOutputPixelFormat(c.AV_PIX_FMT_RGBA, &formats));
}

test "decodeFormatTag maps yuv420p and nv12" {
    try std.testing.expectEqual(@as(c_int, c.VIDEO_FRAME_FORMAT_YUV420P), decodeFormatTag(c.AV_PIX_FMT_YUV420P));
    try std.testing.expectEqual(@as(c_int, c.VIDEO_FRAME_FORMAT_NV12), decodeFormatTag(c.AV_PIX_FMT_NV12));
}

test "decodeFormatTag defaults unknown formats to rgba" {
    try std.testing.expectEqual(@as(c_int, c.VIDEO_FRAME_FORMAT_RGBA), decodeFormatTag(c.AV_PIX_FMT_RGBA));
    try std.testing.expectEqual(@as(c_int, c.VIDEO_FRAME_FORMAT_RGBA), decodeFormatTag(c.AV_PIX_FMT_GRAY8));
}

test "planeCountForFormatTag reports expected yuv plane counts" {
    try std.testing.expectEqual(@as(c_int, 1), planeCountForFormatTag(c.VIDEO_FRAME_FORMAT_RGBA));
    try std.testing.expectEqual(@as(c_int, 3), planeCountForFormatTag(c.VIDEO_FRAME_FORMAT_YUV420P));
    try std.testing.expectEqual(@as(c_int, 2), planeCountForFormatTag(c.VIDEO_FRAME_FORMAT_NV12));
}

test "video_decoder true path maps videotoolbox source metadata to nv12" {
    try std.testing.expectEqual(@as(c_int, c.VIDEO_FRAME_FORMAT_NV12), decodeFormatTag(c.AV_PIX_FMT_VIDEOTOOLBOX));
}

test "video_decoder maps windows hardware metadata to nv12" {
    try std.testing.expectEqual(@as(c_int, c.VIDEO_FRAME_FORMAT_NV12), decodeFormatTag(c.AV_PIX_FMT_D3D11));
    try std.testing.expectEqual(@as(c_int, c.VIDEO_FRAME_FORMAT_NV12), decodeFormatTag(c.AV_PIX_FMT_DXVA2_VLD));
}

test "parseHwDecodePolicy handles supported values" {
    try std.testing.expectEqual(HwDecodePolicy.auto, parseHwDecodePolicy("auto"));
    try std.testing.expectEqual(HwDecodePolicy.off, parseHwDecodePolicy("off"));
    try std.testing.expectEqual(HwDecodePolicy.off, parseHwDecodePolicy("0"));
    try std.testing.expectEqual(HwDecodePolicy.d3d11va, parseHwDecodePolicy("d3d11va"));
    try std.testing.expectEqual(HwDecodePolicy.d3d11va, parseHwDecodePolicy("d3d11"));
    try std.testing.expectEqual(HwDecodePolicy.dxva2, parseHwDecodePolicy("dxva2"));
    try std.testing.expectEqual(HwDecodePolicy.videotoolbox, parseHwDecodePolicy("videotoolbox"));
    try std.testing.expectEqual(HwDecodePolicy.auto, parseHwDecodePolicy("unknown"));
}
