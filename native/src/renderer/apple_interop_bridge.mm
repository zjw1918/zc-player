#ifdef __APPLE__

#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

extern "C" {
#include <libavutil/frame.h>
}

#include "renderer/apple_interop_bridge.h"

static id<MTLDevice> interop_device = nil;
static CVMetalTextureCacheRef interop_cache = NULL;

static int ensure_cache() {
    if (interop_cache != NULL) {
        return 0;
    }

    interop_device = MTLCreateSystemDefaultDevice();
    if (interop_device == nil) {
        return -1;
    }

    CVReturn result = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, interop_device, NULL, &interop_cache);
    return result == kCVReturnSuccess ? 0 : -1;
}

uint64_t apple_interop_create_mtl_texture_from_avframe(uint64_t avframe_token, int plane, int* out_width, int* out_height) {
    if (avframe_token == 0 || out_width == NULL || out_height == NULL) {
        return 0;
    }

    if (ensure_cache() != 0) {
        return 0;
    }

    AVFrame* frame = (AVFrame*)(uintptr_t)avframe_token;
    if (frame == NULL || frame->data[3] == NULL) {
        return 0;
    }

    CVPixelBufferRef pixel_buffer = (CVPixelBufferRef)frame->data[3];
    if (CVPixelBufferGetPlaneCount(pixel_buffer) < (size_t)(plane + 1)) {
        return 0;
    }

    const size_t plane_width = CVPixelBufferGetWidthOfPlane(pixel_buffer, (size_t)plane);
    const size_t plane_height = CVPixelBufferGetHeightOfPlane(pixel_buffer, (size_t)plane);
    MTLPixelFormat pixel_format = (plane == 0) ? MTLPixelFormatR8Unorm : MTLPixelFormatRG8Unorm;

    CVMetalTextureRef cv_texture = NULL;
    CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault,
        interop_cache,
        pixel_buffer,
        NULL,
        pixel_format,
        plane_width,
        plane_height,
        (size_t)plane,
        &cv_texture
    );
    if (result != kCVReturnSuccess || cv_texture == NULL) {
        return 0;
    }

    id<MTLTexture> texture = CVMetalTextureGetTexture(cv_texture);
    if (texture == nil) {
        CFRelease(cv_texture);
        return 0;
    }

    [texture retain];
    CFRelease(cv_texture);

    *out_width = (int)plane_width;
    *out_height = (int)plane_height;
    return (uint64_t)(uintptr_t)texture;
}

void apple_interop_release_mtl_texture(uint64_t texture_token) {
    if (texture_token == 0) {
        return;
    }

    id<MTLTexture> texture = (id<MTLTexture>)(uintptr_t)texture_token;
    [texture release];
}

#else

#include "renderer/apple_interop_bridge.h"

uint64_t apple_interop_create_mtl_texture_from_avframe(uint64_t avframe_token, int plane, int* out_width, int* out_height) {
    (void)avframe_token;
    (void)plane;
    (void)out_width;
    (void)out_height;
    return 0;
}

void apple_interop_release_mtl_texture(uint64_t texture_token) {
    (void)texture_token;
}

#endif
