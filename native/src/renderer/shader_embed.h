#ifndef CPLAYER_SHADER_EMBED_H
#define CPLAYER_SHADER_EMBED_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const uint8_t* zc_shader_video_vert_spv_ptr(void);
size_t zc_shader_video_vert_spv_len(void);
const uint8_t* zc_shader_video_frag_spv_ptr(void);
size_t zc_shader_video_frag_spv_len(void);

#ifdef __cplusplus
}
#endif

#endif
