#include "renderer.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VIDEO_FORMAT_RGBA 0
#define VIDEO_FORMAT_NV12 1
#define VIDEO_FORMAT_YUV420P 2

typedef struct {
    int mode;
} VideoPushConstants;

static VkShaderModule create_shader_module_from_file(VkDevice device, const char* filepath) {
    FILE* f = fopen(filepath, "rb");
    if (!f) {
        fprintf(stderr, "Failed to open shader: %s\n", filepath);
        return VK_NULL_HANDLE;
    }

    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);

    char* data = malloc(size);
    fread(data, 1, size, f);
    fclose(f);

    VkShaderModuleCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = (size_t)size,
        .pCode = (uint32_t*)data,
    };

    VkShaderModule module;
    VkResult result = vkCreateShaderModule(device, &info, NULL, &module);
    free(data);

    if (result != VK_SUCCESS) {
        fprintf(stderr, "Failed to create shader module: %d\n", result);
        return VK_NULL_HANDLE;
    }

    return module;
}

static uint32_t find_memory_type(App* app, uint32_t type_filter, VkMemoryPropertyFlags properties) {
    VkPhysicalDeviceMemoryProperties mem_props;
    vkGetPhysicalDeviceMemoryProperties(app->gpu, &mem_props);

    for (uint32_t i = 0; i < mem_props.memoryTypeCount; i++) {
        if ((type_filter & (1u << i)) && (mem_props.memoryTypes[i].propertyFlags & properties) == properties) {
            return i;
        }
    }

    return UINT32_MAX;
}

static int create_buffer(App* app, VkDeviceSize size, VkBufferUsageFlags usage, VkMemoryPropertyFlags properties, VkBuffer* buffer, VkDeviceMemory* memory) {
    VkBufferCreateInfo buffer_info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = usage,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    if (vkCreateBuffer(app->device, &buffer_info, NULL, buffer) != VK_SUCCESS) {
        return -1;
    }

    VkMemoryRequirements mem_reqs;
    vkGetBufferMemoryRequirements(app->device, *buffer, &mem_reqs);

    uint32_t memory_type_index = find_memory_type(app, mem_reqs.memoryTypeBits, properties);
    if (memory_type_index == UINT32_MAX) {
        return -1;
    }

    VkMemoryAllocateInfo mem_info = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_reqs.size,
        .memoryTypeIndex = memory_type_index,
    };
    if (vkAllocateMemory(app->device, &mem_info, NULL, memory) != VK_SUCCESS) {
        return -1;
    }

    if (vkBindBufferMemory(app->device, *buffer, *memory, 0) != VK_SUCCESS) {
        return -1;
    }

    return 0;
}

static int create_video_plane_resources(App* app, int width, int height, VkFormat format, VkImage* image, VkDeviceMemory* image_memory, VkImageView* image_view, VkBuffer* staging_buffer, VkDeviceMemory* staging_memory, uint8_t** staging_mapped) {
    VkDeviceSize data_size = (VkDeviceSize)(size_t)width * (VkDeviceSize)(size_t)height;
    if (format == VK_FORMAT_R8G8_UNORM) {
        data_size *= 2;
    }

    if (create_buffer(app, data_size, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, staging_buffer, staging_memory) != 0) {
        return -1;
    }

    void* mapped = NULL;
    if (vkMapMemory(app->device, *staging_memory, 0, data_size, 0, &mapped) != VK_SUCCESS) {
        return -1;
    }
    *staging_mapped = (uint8_t*)mapped;

    VkImageCreateInfo image_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = format,
        .extent = {(uint32_t)width, (uint32_t)height, 1},
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    if (vkCreateImage(app->device, &image_info, NULL, image) != VK_SUCCESS) {
        return -1;
    }

    VkMemoryRequirements mem_reqs;
    vkGetImageMemoryRequirements(app->device, *image, &mem_reqs);

    uint32_t memory_type_index = find_memory_type(app, mem_reqs.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (memory_type_index == UINT32_MAX) {
        return -1;
    }

    VkMemoryAllocateInfo mem_info = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_reqs.size,
        .memoryTypeIndex = memory_type_index,
    };
    if (vkAllocateMemory(app->device, &mem_info, NULL, image_memory) != VK_SUCCESS) {
        return -1;
    }

    if (vkBindImageMemory(app->device, *image, *image_memory, 0) != VK_SUCCESS) {
        return -1;
    }

    VkImageViewCreateInfo view_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = *image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = format,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    if (vkCreateImageView(app->device, &view_info, NULL, image_view) != VK_SUCCESS) {
        return -1;
    }

    return 0;
}

static void update_slot_descriptor(Renderer* ren, RendererVideoSlot* slot) {
    VkImageView rgba_view = slot->image_view;
    VkImageView y_view = slot->image_view;
    VkImageView uv_or_u_view = slot->uv_image_view ? slot->uv_image_view : slot->image_view;
    VkImageView v_view = slot->v_image_view ? slot->v_image_view : uv_or_u_view;

    VkDescriptorImageInfo image_infos[4] = {
        {
            .sampler = ren->video_sampler,
            .imageView = rgba_view,
            .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        },
        {
            .sampler = ren->video_sampler,
            .imageView = y_view,
            .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        },
        {
            .sampler = ren->video_sampler,
            .imageView = uv_or_u_view,
            .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        },
        {
            .sampler = ren->video_sampler,
            .imageView = v_view,
            .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        },
    };

    VkWriteDescriptorSet writes[4] = {
        {
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = slot->descriptor_set,
            .dstBinding = 0,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &image_infos[0],
        },
        {
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = slot->descriptor_set,
            .dstBinding = 1,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &image_infos[1],
        },
        {
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = slot->descriptor_set,
            .dstBinding = 2,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &image_infos[2],
        },
        {
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = slot->descriptor_set,
            .dstBinding = 3,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &image_infos[3],
        },
    };

    vkUpdateDescriptorSets(ren->app->device, 4, writes, 0, NULL);
}

static void destroy_video_slot_resources(Renderer* ren, RendererVideoSlot* slot) {
    App* app = ren->app;

    if (slot->staging_memory && slot->staging_mapped) {
        vkUnmapMemory(app->device, slot->staging_memory);
        slot->staging_mapped = NULL;
    }

    if (slot->image_view) {
        vkDestroyImageView(app->device, slot->image_view, NULL);
        slot->image_view = VK_NULL_HANDLE;
    }
    if (slot->image) {
        vkDestroyImage(app->device, slot->image, NULL);
        slot->image = VK_NULL_HANDLE;
    }
    if (slot->image_memory) {
        vkFreeMemory(app->device, slot->image_memory, NULL);
        slot->image_memory = VK_NULL_HANDLE;
    }
    if (slot->staging_buffer) {
        vkDestroyBuffer(app->device, slot->staging_buffer, NULL);
        slot->staging_buffer = VK_NULL_HANDLE;
    }
    if (slot->staging_memory) {
        vkFreeMemory(app->device, slot->staging_memory, NULL);
        slot->staging_memory = VK_NULL_HANDLE;
    }

    if (slot->uv_staging_memory && slot->uv_staging_mapped) {
        vkUnmapMemory(app->device, slot->uv_staging_memory);
        slot->uv_staging_mapped = NULL;
    }

    if (slot->uv_image_view) {
        vkDestroyImageView(app->device, slot->uv_image_view, NULL);
        slot->uv_image_view = VK_NULL_HANDLE;
    }
    if (slot->uv_image) {
        vkDestroyImage(app->device, slot->uv_image, NULL);
        slot->uv_image = VK_NULL_HANDLE;
    }
    if (slot->uv_image_memory) {
        vkFreeMemory(app->device, slot->uv_image_memory, NULL);
        slot->uv_image_memory = VK_NULL_HANDLE;
    }
    if (slot->uv_staging_buffer) {
        vkDestroyBuffer(app->device, slot->uv_staging_buffer, NULL);
        slot->uv_staging_buffer = VK_NULL_HANDLE;
    }
    if (slot->uv_staging_memory) {
        vkFreeMemory(app->device, slot->uv_staging_memory, NULL);
        slot->uv_staging_memory = VK_NULL_HANDLE;
    }

    if (slot->v_staging_memory && slot->v_staging_mapped) {
        vkUnmapMemory(app->device, slot->v_staging_memory);
        slot->v_staging_mapped = NULL;
    }

    if (slot->v_image_view) {
        vkDestroyImageView(app->device, slot->v_image_view, NULL);
        slot->v_image_view = VK_NULL_HANDLE;
    }
    if (slot->v_image) {
        vkDestroyImage(app->device, slot->v_image, NULL);
        slot->v_image = VK_NULL_HANDLE;
    }
    if (slot->v_image_memory) {
        vkFreeMemory(app->device, slot->v_image_memory, NULL);
        slot->v_image_memory = VK_NULL_HANDLE;
    }
    if (slot->v_staging_buffer) {
        vkDestroyBuffer(app->device, slot->v_staging_buffer, NULL);
        slot->v_staging_buffer = VK_NULL_HANDLE;
    }
    if (slot->v_staging_memory) {
        vkFreeMemory(app->device, slot->v_staging_memory, NULL);
        slot->v_staging_memory = VK_NULL_HANDLE;
    }

    slot->image_initialized = 0;
    slot->yuv_initialized = 0;
}

static int create_video_slot_resources(Renderer* ren, RendererVideoSlot* slot, int width, int height) {
    if (create_video_plane_resources(ren->app, width, height, VK_FORMAT_R8G8B8A8_UNORM, &slot->image, &slot->image_memory, &slot->image_view, &slot->staging_buffer, &slot->staging_memory, &slot->staging_mapped) != 0) {
        destroy_video_slot_resources(ren, slot);
        return -1;
    }

    update_slot_descriptor(ren, slot);

    slot->yuv_initialized = 0;
    slot->image_initialized = 0;
    return 0;
}

static int create_video_slot_resources_nv12(Renderer* ren, RendererVideoSlot* slot, int width, int height) {
    int chroma_width = (width + 1) / 2;
    int chroma_height = (height + 1) / 2;

    if (create_video_plane_resources(ren->app, width, height, VK_FORMAT_R8_UNORM, &slot->image, &slot->image_memory, &slot->image_view, &slot->staging_buffer, &slot->staging_memory, &slot->staging_mapped) != 0) {
        destroy_video_slot_resources(ren, slot);
        return -1;
    }
    if (create_video_plane_resources(ren->app, chroma_width, chroma_height, VK_FORMAT_R8G8_UNORM, &slot->uv_image, &slot->uv_image_memory, &slot->uv_image_view, &slot->uv_staging_buffer, &slot->uv_staging_memory, &slot->uv_staging_mapped) != 0) {
        destroy_video_slot_resources(ren, slot);
        return -1;
    }

    update_slot_descriptor(ren, slot);

    slot->yuv_initialized = 1;
    slot->image_initialized = 0;
    return 0;
}

static int create_video_slot_resources_yuv420p(Renderer* ren, RendererVideoSlot* slot, int width, int height) {
    int chroma_width = (width + 1) / 2;
    int chroma_height = (height + 1) / 2;

    if (create_video_plane_resources(ren->app, width, height, VK_FORMAT_R8_UNORM, &slot->image, &slot->image_memory, &slot->image_view, &slot->staging_buffer, &slot->staging_memory, &slot->staging_mapped) != 0) {
        destroy_video_slot_resources(ren, slot);
        return -1;
    }
    if (create_video_plane_resources(ren->app, chroma_width, chroma_height, VK_FORMAT_R8_UNORM, &slot->uv_image, &slot->uv_image_memory, &slot->uv_image_view, &slot->uv_staging_buffer, &slot->uv_staging_memory, &slot->uv_staging_mapped) != 0) {
        destroy_video_slot_resources(ren, slot);
        return -1;
    }
    if (create_video_plane_resources(ren->app, chroma_width, chroma_height, VK_FORMAT_R8_UNORM, &slot->v_image, &slot->v_image_memory, &slot->v_image_view, &slot->v_staging_buffer, &slot->v_staging_memory, &slot->v_staging_mapped) != 0) {
        destroy_video_slot_resources(ren, slot);
        return -1;
    }

    update_slot_descriptor(ren, slot);

    slot->yuv_initialized = 1;
    slot->image_initialized = 0;
    return 0;
}

static int recreate_video_resources(Renderer* ren, int width, int height, int video_format) {
    for (uint32_t i = 0; i < VIDEO_UPLOAD_SLOTS; i++) {
        destroy_video_slot_resources(ren, &ren->video_slots[i]);
    }

    for (uint32_t i = 0; i < VIDEO_UPLOAD_SLOTS; i++) {
        int result = -1;
        if (video_format == VIDEO_FORMAT_RGBA) {
            result = create_video_slot_resources(ren, &ren->video_slots[i], width, height);
        } else if (video_format == VIDEO_FORMAT_NV12) {
            result = create_video_slot_resources_nv12(ren, &ren->video_slots[i], width, height);
        } else if (video_format == VIDEO_FORMAT_YUV420P) {
            result = create_video_slot_resources_yuv420p(ren, &ren->video_slots[i], width, height);
        }

        if (result != 0) {
            return -1;
        }
    }

    ren->video_width = width;
    ren->video_height = height;
    ren->video_format = video_format;
    ren->active_slot = 0;
    ren->next_slot = 0;
    ren->has_video = 0;
    return 0;
}

static int acquire_upload_slot(Renderer* ren, uint32_t* out_slot_index) {
    App* app = ren->app;

    for (uint32_t i = 0; i < VIDEO_UPLOAD_SLOTS; i++) {
        uint32_t idx = (ren->next_slot + i) % VIDEO_UPLOAD_SLOTS;
        RendererVideoSlot* slot = &ren->video_slots[idx];

        VkResult status = vkGetFenceStatus(app->device, slot->upload_fence);
        if (status == VK_SUCCESS) {
            if (vkResetFences(app->device, 1, &slot->upload_fence) != VK_SUCCESS) {
                return -1;
            }

            ren->next_slot = (idx + 1) % VIDEO_UPLOAD_SLOTS;
            *out_slot_index = idx;
            return 0;
        }

        if (status != VK_NOT_READY) {
            return -1;
        }
    }

    return 1;
}

static void copy_plane_rows(uint8_t* dst, size_t dst_row_size, const uint8_t* src, int src_linesize, int rows) {
    for (int y = 0; y < rows; y++) {
        memcpy(dst + ((size_t)y * dst_row_size), src + ((size_t)y * (size_t)src_linesize), dst_row_size);
    }
}

static int create_graphics_pipeline(Renderer* ren) {
    App* app = ren->app;
    if (!app || !app->device || !app->render_pass || !ren->pipeline_layout || !ren->vert_module || !ren->frag_module) {
        return -1;
    }

    VkPipelineShaderStageCreateInfo stages[] = {
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = ren->vert_module, .pName = "main"},
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = ren->frag_module, .pName = "main"},
    };

    VkPipelineVertexInputStateCreateInfo vertex_input = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = 0,
        .pVertexBindingDescriptions = NULL,
        .vertexAttributeDescriptionCount = 0,
        .pVertexAttributeDescriptions = NULL,
    };

    VkPipelineInputAssemblyStateCreateInfo assembly = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    };

    VkViewport viewport = {
        .x = 0,
        .y = 0,
        .width = (float)app->swapchain_extent.width,
        .height = (float)app->swapchain_extent.height,
        .minDepth = 0,
        .maxDepth = 1,
    };
    VkRect2D scissor = {
        .offset = {0, 0},
        .extent = app->swapchain_extent,
    };
    VkPipelineViewportStateCreateInfo viewport_state = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .pViewports = &viewport,
        .scissorCount = 1,
        .pScissors = &scissor,
    };

    VkPipelineRasterizationStateCreateInfo raster = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = VK_POLYGON_MODE_FILL,
        .cullMode = VK_CULL_MODE_NONE,
        .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .lineWidth = 1.0f,
    };

    VkPipelineMultisampleStateCreateInfo multisample = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
    };

    VkPipelineColorBlendAttachmentState blend_attachment = {
        .blendEnable = VK_FALSE,
        .colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
    };
    VkPipelineColorBlendStateCreateInfo blend = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &blend_attachment,
    };

    VkDynamicState dynamic_states[] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dynamic_state = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = 2,
        .pDynamicStates = dynamic_states,
    };

    VkGraphicsPipelineCreateInfo pipeline_info = {
        .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2,
        .pStages = stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &raster,
        .pMultisampleState = &multisample,
        .pColorBlendState = &blend,
        .pDynamicState = &dynamic_state,
        .layout = ren->pipeline_layout,
        .renderPass = app->render_pass,
        .subpass = 0,
    };
    if (vkCreateGraphicsPipelines(app->device, VK_NULL_HANDLE, 1, &pipeline_info, NULL, &ren->pipeline) != VK_SUCCESS) {
        return -1;
    }

    return 0;
}

int renderer_init(Renderer* ren, App* app) {
    memset(ren, 0, sizeof(Renderer));
    ren->app = app;

    ren->vert_module = create_shader_module_from_file(app->device, "src/shaders/video.vert.spv");
    if (!ren->vert_module) {
        goto fail;
    }

    ren->frag_module = create_shader_module_from_file(app->device, "src/shaders/video.frag.spv");
    if (!ren->frag_module) {
        goto fail;
    }

    VkDescriptorSetLayoutBinding sampler_bindings[4] = {
        {
            .binding = 0,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
        },
        {
            .binding = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
        },
        {
            .binding = 2,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
        },
        {
            .binding = 3,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
        },
    };
    VkDescriptorSetLayoutCreateInfo descriptor_layout_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 4,
        .pBindings = sampler_bindings,
    };
    if (vkCreateDescriptorSetLayout(app->device, &descriptor_layout_info, NULL, &ren->descriptor_layout) != VK_SUCCESS) {
        goto fail;
    }

    VkDescriptorPoolSize descriptor_pool_size = {
        .type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = VIDEO_UPLOAD_SLOTS * 4,
    };
    VkDescriptorPoolCreateInfo descriptor_pool_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .poolSizeCount = 1,
        .pPoolSizes = &descriptor_pool_size,
        .maxSets = VIDEO_UPLOAD_SLOTS,
    };
    if (vkCreateDescriptorPool(app->device, &descriptor_pool_info, NULL, &ren->descriptor_pool) != VK_SUCCESS) {
        goto fail;
    }

    VkDescriptorSetLayout set_layouts[VIDEO_UPLOAD_SLOTS];
    for (uint32_t i = 0; i < VIDEO_UPLOAD_SLOTS; i++) {
        set_layouts[i] = ren->descriptor_layout;
    }

    VkDescriptorSetAllocateInfo descriptor_set_alloc_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = ren->descriptor_pool,
        .descriptorSetCount = VIDEO_UPLOAD_SLOTS,
        .pSetLayouts = set_layouts,
    };
    VkDescriptorSet descriptor_sets[VIDEO_UPLOAD_SLOTS];
    if (vkAllocateDescriptorSets(app->device, &descriptor_set_alloc_info, descriptor_sets) != VK_SUCCESS) {
        goto fail;
    }

    for (uint32_t i = 0; i < VIDEO_UPLOAD_SLOTS; i++) {
        ren->video_slots[i].descriptor_set = descriptor_sets[i];
    }

    VkSamplerCreateInfo sampler_info = {
        .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = VK_FILTER_LINEAR,
        .minFilter = VK_FILTER_LINEAR,
        .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR,
        .maxLod = 1.0f,
    };
    if (vkCreateSampler(app->device, &sampler_info, NULL, &ren->video_sampler) != VK_SUCCESS) {
        goto fail;
    }

    VkCommandBufferAllocateInfo upload_alloc_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = app->command_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = VIDEO_UPLOAD_SLOTS,
    };
    VkCommandBuffer upload_cmds[VIDEO_UPLOAD_SLOTS];
    if (vkAllocateCommandBuffers(app->device, &upload_alloc_info, upload_cmds) != VK_SUCCESS) {
        goto fail;
    }

    VkFenceCreateInfo upload_fence_info = {
        .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = VK_FENCE_CREATE_SIGNALED_BIT,
    };
    for (uint32_t i = 0; i < VIDEO_UPLOAD_SLOTS; i++) {
        ren->video_slots[i].upload_cmd = upload_cmds[i];
        if (vkCreateFence(app->device, &upload_fence_info, NULL, &ren->video_slots[i].upload_fence) != VK_SUCCESS) {
            goto fail;
        }
    }

    float vertices[] = {
        -1.0f, -1.0f, 0.0f, 1.0f,
         1.0f, -1.0f, 1.0f, 1.0f,
        -1.0f,  1.0f, 0.0f, 0.0f,
         1.0f,  1.0f, 1.0f, 0.0f,
    };
    if (create_buffer(app, sizeof(vertices), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &ren->vertex_buffer, &ren->vertex_memory) != 0) {
        goto fail;
    }

    void* mapped;
    vkMapMemory(app->device, ren->vertex_memory, 0, sizeof(vertices), 0, &mapped);
    memcpy(mapped, vertices, sizeof(vertices));
    vkUnmapMemory(app->device, ren->vertex_memory);

    VkPushConstantRange push_constant_range = {
        .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
        .offset = 0,
        .size = sizeof(VideoPushConstants),
    };
    VkPipelineLayoutCreateInfo pipeline_layout_info = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &ren->descriptor_layout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_constant_range,
    };
    if (vkCreatePipelineLayout(app->device, &pipeline_layout_info, NULL, &ren->pipeline_layout) != VK_SUCCESS) {
        goto fail;
    }

    if (create_graphics_pipeline(ren) != 0) {
        goto fail;
    }

    ren->active_slot = 0;
    ren->next_slot = 0;
    ren->has_video = 0;
    ren->video_width = 0;
    ren->video_height = 0;
    ren->video_format = VIDEO_FORMAT_RGBA;
    return 0;

fail:
    renderer_destroy(ren);
    return -1;
}

void renderer_destroy(Renderer* ren) {
    App* app = ren->app;
    if (app && app->device) {
        vkDeviceWaitIdle(app->device);
    }

    for (uint32_t i = 0; i < VIDEO_UPLOAD_SLOTS; i++) {
        destroy_video_slot_resources(ren, &ren->video_slots[i]);
        if (ren->video_slots[i].upload_fence) {
            vkDestroyFence(app->device, ren->video_slots[i].upload_fence, NULL);
            ren->video_slots[i].upload_fence = VK_NULL_HANDLE;
        }
        if (ren->video_slots[i].upload_cmd) {
            vkFreeCommandBuffers(app->device, app->command_pool, 1, &ren->video_slots[i].upload_cmd);
            ren->video_slots[i].upload_cmd = VK_NULL_HANDLE;
        }
    }

    if (ren->video_sampler) {
        vkDestroySampler(app->device, ren->video_sampler, NULL);
        ren->video_sampler = VK_NULL_HANDLE;
    }
    if (ren->pipeline) {
        vkDestroyPipeline(app->device, ren->pipeline, NULL);
        ren->pipeline = VK_NULL_HANDLE;
    }
    if (ren->pipeline_layout) {
        vkDestroyPipelineLayout(app->device, ren->pipeline_layout, NULL);
        ren->pipeline_layout = VK_NULL_HANDLE;
    }
    if (ren->descriptor_pool) {
        vkDestroyDescriptorPool(app->device, ren->descriptor_pool, NULL);
        ren->descriptor_pool = VK_NULL_HANDLE;
    }
    if (ren->descriptor_layout) {
        vkDestroyDescriptorSetLayout(app->device, ren->descriptor_layout, NULL);
        ren->descriptor_layout = VK_NULL_HANDLE;
    }
    if (ren->vert_module) {
        vkDestroyShaderModule(app->device, ren->vert_module, NULL);
        ren->vert_module = VK_NULL_HANDLE;
    }
    if (ren->frag_module) {
        vkDestroyShaderModule(app->device, ren->frag_module, NULL);
        ren->frag_module = VK_NULL_HANDLE;
    }
    if (ren->vertex_buffer) {
        vkDestroyBuffer(app->device, ren->vertex_buffer, NULL);
        ren->vertex_buffer = VK_NULL_HANDLE;
    }
    if (ren->vertex_memory) {
        vkFreeMemory(app->device, ren->vertex_memory, NULL);
        ren->vertex_memory = VK_NULL_HANDLE;
    }
}

int renderer_recreate_for_swapchain(Renderer* ren) {
    if (!ren || !ren->app || !ren->app->device) {
        return -1;
    }

    if (ren->pipeline) {
        vkDestroyPipeline(ren->app->device, ren->pipeline, NULL);
        ren->pipeline = VK_NULL_HANDLE;
    }

    return create_graphics_pipeline(ren);
}

int renderer_upload_video(Renderer* ren, uint8_t* data, int width, int height, int linesize) {
    App* app = ren->app;

    if (width <= 0 || height <= 0 || !data) {
        return -1;
    }

    size_t row_size = (size_t)width * 4;
    if (linesize < (int)row_size) {
        return -1;
    }

    if (ren->video_width != width || ren->video_height != height || ren->video_format != VIDEO_FORMAT_RGBA || ren->video_slots[0].image == VK_NULL_HANDLE) {
        if (recreate_video_resources(ren, width, height, VIDEO_FORMAT_RGBA) != 0) {
            return -1;
        }
    }

    uint32_t slot_index = 0;
    int slot_status = acquire_upload_slot(ren, &slot_index);
    if (slot_status != 0) {
        return slot_status > 0 ? 1 : -1;
    }

    RendererVideoSlot* slot = &ren->video_slots[slot_index];

    if (slot->staging_mapped == NULL) {
        return -1;
    }
    copy_plane_rows(slot->staging_mapped, row_size, data, linesize, height);

    if (vkResetCommandBuffer(slot->upload_cmd, 0) != VK_SUCCESS) {
        return -1;
    }

    VkCommandBufferBeginInfo begin_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    if (vkBeginCommandBuffer(slot->upload_cmd, &begin_info) != VK_SUCCESS) {
        return -1;
    }

    VkImageMemoryBarrier pre_barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .oldLayout = slot->image_initialized ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = slot->image,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .srcAccessMask = slot->image_initialized ? VK_ACCESS_SHADER_READ_BIT : 0,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
    };
    VkPipelineStageFlags pre_src_stage = slot->image_initialized ? VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT : VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
    vkCmdPipelineBarrier(slot->upload_cmd, pre_src_stage, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &pre_barrier);

    VkBufferImageCopy region = {
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = {0, 0, 0},
        .imageExtent = {(uint32_t)width, (uint32_t)height, 1},
    };
    vkCmdCopyBufferToImage(slot->upload_cmd, slot->staging_buffer, slot->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

    VkImageMemoryBarrier post_barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = slot->image,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
    };
    vkCmdPipelineBarrier(slot->upload_cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, NULL, 0, NULL, 1, &post_barrier);

    if (vkEndCommandBuffer(slot->upload_cmd) != VK_SUCCESS) {
        return -1;
    }

    VkSubmitInfo submit_info = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &slot->upload_cmd,
    };
    if (vkQueueSubmit(app->graphics_queue, 1, &submit_info, slot->upload_fence) != VK_SUCCESS) {
        return -1;
    }

    slot->image_initialized = 1;
    ren->active_slot = slot_index;
    ren->has_video = 1;
    return 0;
}

int renderer_upload_video_nv12(Renderer* ren, uint8_t* y_plane, int y_linesize, uint8_t* uv_plane, int uv_linesize, int width, int height) {
    App* app = ren->app;
    int chroma_width = (width + 1) / 2;
    int chroma_height = (height + 1) / 2;
    size_t y_row_size = (size_t)width;
    size_t uv_row_size = (size_t)chroma_width * 2;

    if (width <= 0 || height <= 0 || !y_plane || !uv_plane) {
        return -1;
    }
    if (y_linesize < (int)y_row_size || uv_linesize < (int)uv_row_size) {
        return -1;
    }

    if (ren->video_width != width || ren->video_height != height || ren->video_format != VIDEO_FORMAT_NV12 || ren->video_slots[0].image == VK_NULL_HANDLE || ren->video_slots[0].uv_image == VK_NULL_HANDLE) {
        if (recreate_video_resources(ren, width, height, VIDEO_FORMAT_NV12) != 0) {
            return -1;
        }
    }

    uint32_t slot_index = 0;
    int slot_status = acquire_upload_slot(ren, &slot_index);
    if (slot_status != 0) {
        return slot_status > 0 ? 1 : -1;
    }

    RendererVideoSlot* slot = &ren->video_slots[slot_index];

    if (slot->staging_mapped == NULL || slot->uv_staging_mapped == NULL) {
        return -1;
    }
    copy_plane_rows(slot->staging_mapped, y_row_size, y_plane, y_linesize, height);
    copy_plane_rows(slot->uv_staging_mapped, uv_row_size, uv_plane, uv_linesize, chroma_height);

    if (vkResetCommandBuffer(slot->upload_cmd, 0) != VK_SUCCESS) {
        return -1;
    }

    VkCommandBufferBeginInfo begin_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    if (vkBeginCommandBuffer(slot->upload_cmd, &begin_info) != VK_SUCCESS) {
        return -1;
    }

    VkImageMemoryBarrier pre_barriers[2] = {
        {
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .oldLayout = slot->image_initialized ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = slot->image,
            .subresourceRange = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .srcAccessMask = slot->image_initialized ? VK_ACCESS_SHADER_READ_BIT : 0,
            .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        },
        {
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .oldLayout = slot->image_initialized ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = slot->uv_image,
            .subresourceRange = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .srcAccessMask = slot->image_initialized ? VK_ACCESS_SHADER_READ_BIT : 0,
            .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        },
    };
    VkPipelineStageFlags pre_src_stage = slot->image_initialized ? VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT : VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
    vkCmdPipelineBarrier(slot->upload_cmd, pre_src_stage, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 2, pre_barriers);

    VkBufferImageCopy y_region = {
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = {0, 0, 0},
        .imageExtent = {(uint32_t)width, (uint32_t)height, 1},
    };
    vkCmdCopyBufferToImage(slot->upload_cmd, slot->staging_buffer, slot->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &y_region);

    VkBufferImageCopy uv_region = {
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = {0, 0, 0},
        .imageExtent = {(uint32_t)chroma_width, (uint32_t)chroma_height, 1},
    };
    vkCmdCopyBufferToImage(slot->upload_cmd, slot->uv_staging_buffer, slot->uv_image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &uv_region);

    VkImageMemoryBarrier post_barriers[2] = {
        {
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = slot->image,
            .subresourceRange = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
        },
        {
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = slot->uv_image,
            .subresourceRange = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
        },
    };
    vkCmdPipelineBarrier(slot->upload_cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, NULL, 0, NULL, 2, post_barriers);

    if (vkEndCommandBuffer(slot->upload_cmd) != VK_SUCCESS) {
        return -1;
    }

    VkSubmitInfo submit_info = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &slot->upload_cmd,
    };
    if (vkQueueSubmit(app->graphics_queue, 1, &submit_info, slot->upload_fence) != VK_SUCCESS) {
        return -1;
    }

    slot->image_initialized = 1;
    slot->yuv_initialized = 1;
    ren->active_slot = slot_index;
    ren->has_video = 1;
    return 0;
}

int renderer_upload_video_yuv420p(Renderer* ren, uint8_t* y_plane, int y_linesize, uint8_t* u_plane, int u_linesize, uint8_t* v_plane, int v_linesize, int width, int height) {
    App* app = ren->app;
    int chroma_width = (width + 1) / 2;
    int chroma_height = (height + 1) / 2;
    size_t y_row_size = (size_t)width;
    size_t u_row_size = (size_t)chroma_width;
    size_t v_row_size = (size_t)chroma_width;

    if (width <= 0 || height <= 0 || !y_plane || !u_plane || !v_plane) {
        return -1;
    }
    if (y_linesize < (int)y_row_size || u_linesize < (int)u_row_size || v_linesize < (int)v_row_size) {
        return -1;
    }

    if (ren->video_width != width || ren->video_height != height || ren->video_format != VIDEO_FORMAT_YUV420P || ren->video_slots[0].image == VK_NULL_HANDLE || ren->video_slots[0].uv_image == VK_NULL_HANDLE || ren->video_slots[0].v_image == VK_NULL_HANDLE) {
        if (recreate_video_resources(ren, width, height, VIDEO_FORMAT_YUV420P) != 0) {
            return -1;
        }
    }

    uint32_t slot_index = 0;
    int slot_status = acquire_upload_slot(ren, &slot_index);
    if (slot_status != 0) {
        return slot_status > 0 ? 1 : -1;
    }

    RendererVideoSlot* slot = &ren->video_slots[slot_index];

    if (slot->staging_mapped == NULL || slot->uv_staging_mapped == NULL || slot->v_staging_mapped == NULL) {
        return -1;
    }
    copy_plane_rows(slot->staging_mapped, y_row_size, y_plane, y_linesize, height);
    copy_plane_rows(slot->uv_staging_mapped, u_row_size, u_plane, u_linesize, chroma_height);
    copy_plane_rows(slot->v_staging_mapped, v_row_size, v_plane, v_linesize, chroma_height);

    if (vkResetCommandBuffer(slot->upload_cmd, 0) != VK_SUCCESS) {
        return -1;
    }

    VkCommandBufferBeginInfo begin_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    if (vkBeginCommandBuffer(slot->upload_cmd, &begin_info) != VK_SUCCESS) {
        return -1;
    }

    VkImageMemoryBarrier pre_barriers[3] = {
        {
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .oldLayout = slot->image_initialized ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = slot->image,
            .subresourceRange = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .srcAccessMask = slot->image_initialized ? VK_ACCESS_SHADER_READ_BIT : 0,
            .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        },
        {
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .oldLayout = slot->image_initialized ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = slot->uv_image,
            .subresourceRange = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .srcAccessMask = slot->image_initialized ? VK_ACCESS_SHADER_READ_BIT : 0,
            .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        },
        {
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .oldLayout = slot->image_initialized ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = slot->v_image,
            .subresourceRange = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .srcAccessMask = slot->image_initialized ? VK_ACCESS_SHADER_READ_BIT : 0,
            .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        },
    };
    VkPipelineStageFlags pre_src_stage = slot->image_initialized ? VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT : VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
    vkCmdPipelineBarrier(slot->upload_cmd, pre_src_stage, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 3, pre_barriers);

    VkBufferImageCopy y_region = {
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = {0, 0, 0},
        .imageExtent = {(uint32_t)width, (uint32_t)height, 1},
    };
    vkCmdCopyBufferToImage(slot->upload_cmd, slot->staging_buffer, slot->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &y_region);

    VkBufferImageCopy u_region = {
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = {0, 0, 0},
        .imageExtent = {(uint32_t)chroma_width, (uint32_t)chroma_height, 1},
    };
    vkCmdCopyBufferToImage(slot->upload_cmd, slot->uv_staging_buffer, slot->uv_image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &u_region);

    VkBufferImageCopy v_region = {
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = {0, 0, 0},
        .imageExtent = {(uint32_t)chroma_width, (uint32_t)chroma_height, 1},
    };
    vkCmdCopyBufferToImage(slot->upload_cmd, slot->v_staging_buffer, slot->v_image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &v_region);

    VkImageMemoryBarrier post_barriers[3] = {
        {
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = slot->image,
            .subresourceRange = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
        },
        {
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = slot->uv_image,
            .subresourceRange = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
        },
        {
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = slot->v_image,
            .subresourceRange = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
        },
    };
    vkCmdPipelineBarrier(slot->upload_cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, NULL, 0, NULL, 3, post_barriers);

    if (vkEndCommandBuffer(slot->upload_cmd) != VK_SUCCESS) {
        return -1;
    }

    VkSubmitInfo submit_info = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &slot->upload_cmd,
    };
    if (vkQueueSubmit(app->graphics_queue, 1, &submit_info, slot->upload_fence) != VK_SUCCESS) {
        return -1;
    }

    slot->image_initialized = 1;
    slot->yuv_initialized = 1;
    ren->active_slot = slot_index;
    ren->has_video = 1;
    return 0;
}

int renderer_submit_interop_handle(Renderer* ren, uint64_t handle_token, int width, int height, int format) {
    (void)handle_token;

    if (ren == NULL || width <= 0 || height <= 0) {
        return -1;
    }

    /* Placeholder entrypoint for future zero-copy render path wiring. */
    ren->video_width = width;
    ren->video_height = height;
    ren->video_format = format;
    return -1;
}

void renderer_render(Renderer* ren) {
    if (!ren->has_video) {
        return;
    }

    RendererVideoSlot* slot = &ren->video_slots[ren->active_slot];
    if (!slot->image_initialized) {
        return;
    }

    App* app = ren->app;
    VkCommandBuffer cmd = app->command_buffers[app->current_frame];

    float surface_width = (float)app->swapchain_extent.width;
    float surface_height = (float)app->swapchain_extent.height;
    float video_width = (float)ren->video_width;
    float video_height = (float)ren->video_height;

    float viewport_x = 0.0f;
    float viewport_y = 0.0f;
    float viewport_width = surface_width;
    float viewport_height = surface_height;

    if (surface_width > 0.0f && surface_height > 0.0f && video_width > 0.0f && video_height > 0.0f) {
        float surface_aspect = surface_width / surface_height;
        float video_aspect = video_width / video_height;

        if (surface_aspect > video_aspect) {
            viewport_height = surface_height;
            viewport_width = viewport_height * video_aspect;
            viewport_x = (surface_width - viewport_width) * 0.5f;
            viewport_y = 0.0f;
        } else {
            viewport_width = surface_width;
            viewport_height = viewport_width / video_aspect;
            viewport_x = 0.0f;
            viewport_y = (surface_height - viewport_height) * 0.5f;
        }
    }

    VkViewport viewport = {
        .x = viewport_x,
        .y = viewport_y,
        .width = viewport_width,
        .height = viewport_height,
        .minDepth = 0,
        .maxDepth = 1,
    };
    vkCmdSetViewport(cmd, 0, 1, &viewport);

    int32_t scissor_x = (int32_t)viewport_x;
    int32_t scissor_y = (int32_t)viewport_y;
    uint32_t scissor_width = (uint32_t)(viewport_width > 1.0f ? viewport_width : 1.0f);
    uint32_t scissor_height = (uint32_t)(viewport_height > 1.0f ? viewport_height : 1.0f);

    VkRect2D scissor = {
        .offset = {scissor_x, scissor_y},
        .extent = {scissor_width, scissor_height},
    };
    vkCmdSetScissor(cmd, 0, 1, &scissor);

    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, ren->pipeline);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, ren->pipeline_layout, 0, 1, &slot->descriptor_set, 0, NULL);
    VideoPushConstants push_constants = {
        .mode = ren->video_format,
    };
    vkCmdPushConstants(cmd, ren->pipeline_layout, VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(push_constants), &push_constants);
    vkCmdDraw(cmd, 6, 1, 0, 0);
}
