#ifndef CPLAYER_RENDERER_H
#define CPLAYER_RENDERER_H

#include <vulkan/vulkan.h>
#include <stdint.h>
#include "app/app.h"

#define VIDEO_UPLOAD_SLOTS 3

typedef struct {
    VkImage image;
    VkDeviceMemory image_memory;
    VkImageView image_view;
    VkBuffer staging_buffer;
    VkDeviceMemory staging_memory;
    VkCommandBuffer upload_cmd;
    VkFence upload_fence;
    VkDescriptorSet descriptor_set;
    int image_initialized;
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
    int has_video;
} Renderer;

int renderer_init(Renderer* ren, App* app);
void renderer_destroy(Renderer* ren);
int renderer_upload_video(Renderer* ren, uint8_t* data, int width, int height, int linesize);
void renderer_render(Renderer* ren);

#endif
