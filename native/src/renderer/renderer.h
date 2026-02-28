#ifndef CPLAYER_RENDERER_H
#define CPLAYER_RENDERER_H

#include <vulkan/vulkan.h>
#include <stdint.h>
#include "app/app.h"

#define VIDEO_UPLOAD_SLOTS 2

typedef enum {
    RENDERER_INTEROP_PAYLOAD_HOST = 0,
    RENDERER_INTEROP_PAYLOAD_GPU = 1,
} RendererInteropPayloadKind;

typedef struct {
    uint8_t* planes[3];
    int linesizes[3];
    int plane_count;
    int width;
    int height;
    int format;
    int source_is_hw;
    int payload_kind;
    uint64_t gpu_token;
} RendererInteropHostFrame;

typedef struct {
    VkImage image;
    VkDeviceMemory image_memory;
    VkImageView image_view;
    VkBuffer staging_buffer;
    VkDeviceMemory staging_memory;
    uint8_t* staging_mapped;
    VkImage uv_image;
    VkDeviceMemory uv_image_memory;
    VkImageView uv_image_view;
    VkBuffer uv_staging_buffer;
    VkDeviceMemory uv_staging_memory;
    uint8_t* uv_staging_mapped;
    VkImage v_image;
    VkDeviceMemory v_image_memory;
    VkImageView v_image_view;
    VkBuffer v_staging_buffer;
    VkDeviceMemory v_staging_memory;
    uint8_t* v_staging_mapped;
    VkCommandBuffer upload_cmd;
    VkFence upload_fence;
    VkDescriptorSet descriptor_set;
    uint64_t imported_y_texture_token;
    uint64_t imported_uv_texture_token;
    int imported_external;
    int image_initialized;
    int yuv_initialized;
} RendererVideoSlot;

typedef struct {
    App* app;
    VkShaderModule vert_module;
    VkShaderModule frag_module;
    VkDescriptorSetLayout descriptor_layout;
    VkDescriptorPool descriptor_pool;
    VkPipelineLayout pipeline_layout;
    VkPipeline pipeline;
    VkBuffer vertex_buffer;
    VkDeviceMemory vertex_memory;
    VkSampler video_sampler;
    RendererVideoSlot video_slots[VIDEO_UPLOAD_SLOTS];
    uint32_t active_slot;
    uint32_t next_slot;
    int video_width;
    int video_height;
    int video_format;
    int video_image_initialized;
    int video_yuv_initialized;
    int has_video;
} Renderer;

int renderer_init(Renderer* ren, App* app);
void renderer_destroy(Renderer* ren);
int renderer_upload_video(Renderer* ren, uint8_t* data, int width, int height, int linesize);
int renderer_upload_video_nv12(Renderer* ren, uint8_t* y_plane, int y_linesize, uint8_t* uv_plane, int uv_linesize, int width, int height);
int renderer_upload_video_yuv420p(Renderer* ren, uint8_t* y_plane, int y_linesize, uint8_t* u_plane, int u_linesize, uint8_t* v_plane, int v_linesize, int width, int height);
int renderer_submit_interop_handle(Renderer* ren, uint64_t handle_token, int width, int height, int format);
int renderer_submit_true_zero_copy_handle(Renderer* ren, uint64_t handle_token, int width, int height, int format);
int renderer_recreate_for_swapchain(Renderer* ren);
void renderer_trim_video_resources(Renderer* ren);
void renderer_render(Renderer* ren);

#endif
