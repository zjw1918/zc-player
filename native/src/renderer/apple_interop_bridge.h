#ifndef CPLAYER_APPLE_INTEROP_BRIDGE_H
#define CPLAYER_APPLE_INTEROP_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint64_t apple_interop_create_mtl_texture_from_avframe(uint64_t avframe_token, int plane, int* out_width, int* out_height);
void apple_interop_release_mtl_texture(uint64_t texture_token);

#ifdef __cplusplus
}
#endif

#endif
