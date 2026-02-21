#include "app/app.h"
#include <SDL3/SDL_vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ui/ui.h"

#define MAX_FRAMES_IN_FLIGHT 2

static const char* required_validation_layers[] = {
    "VK_LAYER_KHRONOS_validation"
};

static int check_validation_layer_support() {
    uint32_t layer_count;
    vkEnumerateInstanceLayerProperties(&layer_count, NULL);
    VkLayerProperties* available_layers = malloc(layer_count * sizeof(VkLayerProperties));
    if (layer_count > 0 && !available_layers) {
        return 0;
    }
    vkEnumerateInstanceLayerProperties(&layer_count, available_layers);

    for (int i = 0; i < sizeof(required_validation_layers)/sizeof(required_validation_layers[0]); i++) {
        int layer_found = 0;
        for (uint32_t j = 0; j < layer_count; j++) {
            if (strcmp(required_validation_layers[i], available_layers[j].layerName) == 0) {
                layer_found = 1;
                break;
            }
        }
        if (!layer_found) {
            free(available_layers);
            return 0;
        }
    }
    free(available_layers);
    return 1;
}

static int rate_device_suitability(VkPhysicalDevice device) {
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(device, &props);

    int score = 0;
    if (props.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
        score += 1000;
    }
    score += props.limits.maxImageDimension2D;
    return score;
}

static int has_device_extension(VkPhysicalDevice device, const char* extension_name) {
    uint32_t extension_count = 0;
    if (vkEnumerateDeviceExtensionProperties(device, NULL, &extension_count, NULL) != VK_SUCCESS || extension_count == 0) {
        return 0;
    }

    VkExtensionProperties* extensions = malloc(extension_count * sizeof(VkExtensionProperties));
    if (!extensions) {
        return 0;
    }

    if (vkEnumerateDeviceExtensionProperties(device, NULL, &extension_count, extensions) != VK_SUCCESS) {
        free(extensions);
        return 0;
    }

    int found = 0;
    for (uint32_t i = 0; i < extension_count; i++) {
        if (strcmp(extensions[i].extensionName, extension_name) == 0) {
            found = 1;
            break;
        }
    }

    free(extensions);
    return found;
}

static int has_swapchain_support(VkPhysicalDevice device, VkSurfaceKHR surface) {
    uint32_t format_count = 0;
    if (vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, NULL) != VK_SUCCESS || format_count == 0) {
        return 0;
    }

    uint32_t present_mode_count = 0;
    if (vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, NULL) != VK_SUCCESS || present_mode_count == 0) {
        return 0;
    }

    return 1;
}

static int find_graphics_present_queue_family(VkPhysicalDevice device, VkSurfaceKHR surface, uint32_t* out_queue_family) {
    uint32_t queue_family_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, NULL);
    if (queue_family_count == 0) {
        return 0;
    }

    VkQueueFamilyProperties* queue_families = malloc(queue_family_count * sizeof(VkQueueFamilyProperties));
    if (!queue_families) {
        return 0;
    }

    vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families);

    int found = 0;
    uint32_t selected = 0;
    for (uint32_t i = 0; i < queue_family_count; i++) {
        if ((queue_families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) == 0) {
            continue;
        }

        VkBool32 present_supported = VK_FALSE;
        if (vkGetPhysicalDeviceSurfaceSupportKHR(device, i, surface, &present_supported) != VK_SUCCESS) {
            continue;
        }

        if (present_supported == VK_TRUE) {
            selected = i;
            found = 1;
            break;
        }
    }

    free(queue_families);

    if (!found) {
        return 0;
    }

    *out_queue_family = selected;
    return 1;
}

static int is_device_suitable(App* app, VkPhysicalDevice device, uint32_t* out_queue_family, int* out_portability_subset_supported) {
    if (!has_device_extension(device, VK_KHR_SWAPCHAIN_EXTENSION_NAME)) {
        return 0;
    }

    if (!has_swapchain_support(device, app->surface)) {
        return 0;
    }

    uint32_t queue_family = 0;
    if (!find_graphics_present_queue_family(device, app->surface, &queue_family)) {
        return 0;
    }

    *out_queue_family = queue_family;
    *out_portability_subset_supported = has_device_extension(device, "VK_KHR_portability_subset");
    return 1;
}

static int create_instance(App* app) {
    VkApplicationInfo app_info = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "CPlayer",
        .applicationVersion = VK_MAKE_VERSION(1, 0, 0),
        .pEngineName = "No Engine",
        .engineVersion = VK_MAKE_VERSION(1, 0, 0),
        .apiVersion = VK_API_VERSION_1_3,
    };

    uint32_t sdl_ext_count = 0;
    const char* const* sdl_extensions = SDL_Vulkan_GetInstanceExtensions(&sdl_ext_count);
    int has_portability_enumeration = 0;
    for (uint32_t i = 0; i < sdl_ext_count; i++) {
        if (strcmp(sdl_extensions[i], "VK_KHR_portability_enumeration") == 0) {
            has_portability_enumeration = 1;
            break;
        }
    }

    int validation_enabled = check_validation_layer_support();
    printf("Validation layers supported: %d\n", validation_enabled);

    VkInstanceCreateInfo create_info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
        .enabledExtensionCount = sdl_ext_count,
        .ppEnabledExtensionNames = sdl_extensions,
        .enabledLayerCount = validation_enabled ? 1 : 0,
        .ppEnabledLayerNames = validation_enabled ? required_validation_layers : NULL,
        .flags = has_portability_enumeration ? VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0,
    };

    VkResult result = vkCreateInstance(&create_info, NULL, &app->instance);
    return result == VK_SUCCESS ? 0 : -1;
}

static int create_surface(App* app) {
    if (!SDL_Vulkan_CreateSurface(app->window, app->instance, NULL, &app->surface)) {
        return -1;
    }
    return 0;
}

static int pick_physical_device(App* app) {
    uint32_t device_count = 0;
    vkEnumeratePhysicalDevices(app->instance, &device_count, NULL);
    if (device_count == 0) {
        fprintf(stderr, "failed to find GPUs with Vulkan support!\n");
        return -1;
    }

    VkPhysicalDevice* devices = malloc(device_count * sizeof(VkPhysicalDevice));
    if (!devices) {
        return -1;
    }
    vkEnumeratePhysicalDevices(app->instance, &device_count, devices);

    int best_score = -1;
    int best_index = -1;
    uint32_t best_queue_family = 0;
    int best_portability_subset_supported = 0;
    for (uint32_t i = 0; i < device_count; i++) {
        uint32_t queue_family = 0;
        int portability_subset_supported = 0;
        if (!is_device_suitable(app, devices[i], &queue_family, &portability_subset_supported)) {
            continue;
        }

        int score = rate_device_suitability(devices[i]);
        if (score > best_score) {
            best_score = score;
            best_index = i;
            best_queue_family = queue_family;
            best_portability_subset_supported = portability_subset_supported;
        }
    }

    if (best_index == -1) {
        free(devices);
        return -1;
    }

    app->gpu = devices[best_index];
    app->graphics_queue_family = best_queue_family;
    app->portability_subset_supported = best_portability_subset_supported;
    free(devices);
    return 0;
}

static int create_logical_device(App* app) {
    if (app->graphics_queue_family == UINT32_MAX) {
        return -1;
    }

    float queue_priority = 1.0f;
    VkDeviceQueueCreateInfo queue_create_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = app->graphics_queue_family,
        .queueCount = 1,
        .pQueuePriorities = &queue_priority,
    };

    VkPhysicalDeviceFeatures device_features = {};

    const char* device_extensions[2] = {0};
    uint32_t enabled_extension_count = 0;
    device_extensions[enabled_extension_count++] = VK_KHR_SWAPCHAIN_EXTENSION_NAME;
    if (app->portability_subset_supported) {
        device_extensions[enabled_extension_count++] = "VK_KHR_portability_subset";
    }

    VkDeviceCreateInfo device_create_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_create_info,
        .pEnabledFeatures = &device_features,
        .enabledExtensionCount = enabled_extension_count,
        .ppEnabledExtensionNames = device_extensions,
    };

    if (vkCreateDevice(app->gpu, &device_create_info, NULL, &app->device) != VK_SUCCESS) {
        return -1;
    }

    vkGetDeviceQueue(app->device, app->graphics_queue_family, 0, &app->graphics_queue);
    return 0;
}

static int create_swapchain(App* app) {
    VkSurfaceCapabilitiesKHR capabilities;
    if (vkGetPhysicalDeviceSurfaceCapabilitiesKHR(app->gpu, app->surface, &capabilities) != VK_SUCCESS) {
        return -1;
    }

    uint32_t format_count;
    if (vkGetPhysicalDeviceSurfaceFormatsKHR(app->gpu, app->surface, &format_count, NULL) != VK_SUCCESS || format_count == 0) {
        return -1;
    }
    VkSurfaceFormatKHR* formats = malloc(format_count * sizeof(VkSurfaceFormatKHR));
    if (!formats) {
        return -1;
    }
    if (vkGetPhysicalDeviceSurfaceFormatsKHR(app->gpu, app->surface, &format_count, formats) != VK_SUCCESS) {
        free(formats);
        return -1;
    }

    uint32_t present_mode_count;
    if (vkGetPhysicalDeviceSurfacePresentModesKHR(app->gpu, app->surface, &present_mode_count, NULL) != VK_SUCCESS || present_mode_count == 0) {
        free(formats);
        return -1;
    }
    VkPresentModeKHR* present_modes = malloc(present_mode_count * sizeof(VkPresentModeKHR));
    if (!present_modes) {
        free(formats);
        return -1;
    }
    if (vkGetPhysicalDeviceSurfacePresentModesKHR(app->gpu, app->surface, &present_mode_count, present_modes) != VK_SUCCESS) {
        free(formats);
        free(present_modes);
        return -1;
    }

    VkSurfaceFormatKHR surface_format = formats[0];
    for (uint32_t i = 0; i < format_count; i++) {
        if (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM &&
            formats[i].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            surface_format = formats[i];
            break;
        }
    }
    if (surface_format.format != VK_FORMAT_B8G8R8A8_UNORM) {
        for (uint32_t i = 0; i < format_count; i++) {
            if (formats[i].format == VK_FORMAT_R8G8B8A8_UNORM &&
                formats[i].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                surface_format = formats[i];
                break;
            }
        }
    }

    VkPresentModeKHR present_mode = VK_PRESENT_MODE_FIFO_KHR;
    for (uint32_t i = 0; i < present_mode_count; i++) {
        if (present_modes[i] == VK_PRESENT_MODE_MAILBOX_KHR) {
            present_mode = present_modes[i];
            break;
        }
    }

    VkExtent2D extent = {
        .width = capabilities.currentExtent.width,
        .height = capabilities.currentExtent.height,
    };

    if (extent.width == UINT32_MAX) {
        int pixel_width = 0;
        int pixel_height = 0;
        SDL_GetWindowSizeInPixels(app->window, &pixel_width, &pixel_height);
        if (pixel_width <= 0 || pixel_height <= 0) {
            free(formats);
            free(present_modes);
            return -1;
        }
        extent.width = (uint32_t)pixel_width;
        extent.height = (uint32_t)pixel_height;
    }

    uint32_t image_count = capabilities.minImageCount + 1;
    if (capabilities.maxImageCount > 0 && image_count > capabilities.maxImageCount) {
        image_count = capabilities.maxImageCount;
    }

    VkSwapchainCreateInfoKHR create_info = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = app->surface,
        .minImageCount = image_count,
        .imageFormat = surface_format.format,
        .imageColorSpace = surface_format.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = capabilities.currentTransform,
        .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = present_mode,
        .clipped = VK_TRUE,
        .oldSwapchain = VK_NULL_HANDLE,
    };

    if (vkCreateSwapchainKHR(app->device, &create_info, NULL, &app->swapchain) != VK_SUCCESS) {
        free(formats);
        free(present_modes);
        return -1;
    }

    app->swapchain_format = surface_format.format;
    app->swapchain_extent = extent;

    uint32_t actual_image_count;
    if (vkGetSwapchainImagesKHR(app->device, app->swapchain, &actual_image_count, NULL) != VK_SUCCESS || actual_image_count == 0) {
        vkDestroySwapchainKHR(app->device, app->swapchain, NULL);
        app->swapchain = VK_NULL_HANDLE;
        free(formats);
        free(present_modes);
        return -1;
    }
    app->swapchain_images = calloc(actual_image_count, sizeof(VkImage));
    if (!app->swapchain_images) {
        vkDestroySwapchainKHR(app->device, app->swapchain, NULL);
        app->swapchain = VK_NULL_HANDLE;
        free(formats);
        free(present_modes);
        return -1;
    }
    if (vkGetSwapchainImagesKHR(app->device, app->swapchain, &actual_image_count, app->swapchain_images) != VK_SUCCESS) {
        free(app->swapchain_images);
        app->swapchain_images = NULL;
        vkDestroySwapchainKHR(app->device, app->swapchain, NULL);
        app->swapchain = VK_NULL_HANDLE;
        free(formats);
        free(present_modes);
        return -1;
    }
    app->swapchain_image_count = actual_image_count;

    app->swapchain_image_views = calloc(actual_image_count, sizeof(VkImageView));
    if (!app->swapchain_image_views) {
        free(app->swapchain_images);
        app->swapchain_images = NULL;
        vkDestroySwapchainKHR(app->device, app->swapchain, NULL);
        app->swapchain = VK_NULL_HANDLE;
        app->swapchain_image_count = 0;
        free(formats);
        free(present_modes);
        return -1;
    }
    for (uint32_t i = 0; i < actual_image_count; i++) {
        VkImageViewCreateInfo create_info = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = app->swapchain_images[i],
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .format = app->swapchain_format,
            .subresourceRange = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        if (vkCreateImageView(app->device, &create_info, NULL, &app->swapchain_image_views[i]) != VK_SUCCESS) {
            for (uint32_t j = 0; j < i; j++) {
                if (app->swapchain_image_views[j] != VK_NULL_HANDLE) {
                    vkDestroyImageView(app->device, app->swapchain_image_views[j], NULL);
                }
            }
            free(app->swapchain_image_views);
            app->swapchain_image_views = NULL;
            free(app->swapchain_images);
            app->swapchain_images = NULL;
            vkDestroySwapchainKHR(app->device, app->swapchain, NULL);
            app->swapchain = VK_NULL_HANDLE;
            app->swapchain_image_count = 0;
            free(formats);
            free(present_modes);
            return -1;
        }
    }

    free(formats);
    free(present_modes);
    return 0;
}

static int create_render_pass(App* app) {
    VkAttachmentDescription color_attachment = {
        .format = app->swapchain_format,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };

    VkAttachmentReference color_attachment_ref = {
        .attachment = 0,
        .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    VkSubpassDescription subpass = {
        .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment_ref,
    };

    VkSubpassDependency dependency = {
        .srcSubpass = VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = 0,
        .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    };

    VkRenderPassCreateInfo render_pass_info = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &color_attachment,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dependency,
    };

    if (vkCreateRenderPass(app->device, &render_pass_info, NULL, &app->render_pass) != VK_SUCCESS) {
        return -1;
    }
    return 0;
}

static int create_framebuffers(App* app) {
    app->framebuffers = calloc(app->swapchain_image_count, sizeof(VkFramebuffer));
    if (!app->framebuffers) {
        return -1;
    }

    for (uint32_t i = 0; i < app->swapchain_image_count; i++) {
        VkImageView attachments[] = { app->swapchain_image_views[i] };

        VkFramebufferCreateInfo framebuffer_info = {
            .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = app->render_pass,
            .attachmentCount = 1,
            .pAttachments = attachments,
            .width = app->swapchain_extent.width,
            .height = app->swapchain_extent.height,
            .layers = 1,
        };

        if (vkCreateFramebuffer(app->device, &framebuffer_info, NULL, &app->framebuffers[i]) != VK_SUCCESS) {
            for (uint32_t j = 0; j < i; j++) {
                if (app->framebuffers[j] != VK_NULL_HANDLE) {
                    vkDestroyFramebuffer(app->device, app->framebuffers[j], NULL);
                }
            }
            free(app->framebuffers);
            app->framebuffers = NULL;
            return -1;
        }
    }
    return 0;
}

static int create_command_pool(App* app) {
    VkCommandPoolCreateInfo pool_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = app->graphics_queue_family,
    };

    if (vkCreateCommandPool(app->device, &pool_info, NULL, &app->command_pool) != VK_SUCCESS) {
        return -1;
    }
    return 0;
}

static int create_command_buffers(App* app) {
    app->command_buffers = calloc(app->swapchain_image_count, sizeof(VkCommandBuffer));
    if (!app->command_buffers) {
        return -1;
    }

    VkCommandBufferAllocateInfo alloc_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = app->command_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = app->swapchain_image_count,
    };

    if (vkAllocateCommandBuffers(app->device, &alloc_info, app->command_buffers) != VK_SUCCESS) {
        free(app->command_buffers);
        app->command_buffers = NULL;
        return -1;
    }
    return 0;
}

static int create_sync_objects(App* app) {
    app->image_available_semaphores = calloc(app->swapchain_image_count, sizeof(VkSemaphore));
    app->render_finished_semaphores = calloc(app->swapchain_image_count, sizeof(VkSemaphore));
    app->in_flight_fences = calloc(app->swapchain_image_count, sizeof(VkFence));
    if (!app->image_available_semaphores || !app->render_finished_semaphores || !app->in_flight_fences) {
        free(app->image_available_semaphores);
        free(app->render_finished_semaphores);
        free(app->in_flight_fences);
        app->image_available_semaphores = NULL;
        app->render_finished_semaphores = NULL;
        app->in_flight_fences = NULL;
        return -1;
    }

    VkSemaphoreCreateInfo semaphore_info = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    };

    VkFenceCreateInfo fence_info = {
        .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = VK_FENCE_CREATE_SIGNALED_BIT,
    };

    for (uint32_t i = 0; i < app->swapchain_image_count; i++) {
        if (vkCreateSemaphore(app->device, &semaphore_info, NULL, &app->image_available_semaphores[i]) != VK_SUCCESS ||
            vkCreateSemaphore(app->device, &semaphore_info, NULL, &app->render_finished_semaphores[i]) != VK_SUCCESS ||
            vkCreateFence(app->device, &fence_info, NULL, &app->in_flight_fences[i]) != VK_SUCCESS) {
            for (uint32_t j = 0; j <= i; j++) {
                if (app->image_available_semaphores[j] != VK_NULL_HANDLE) {
                    vkDestroySemaphore(app->device, app->image_available_semaphores[j], NULL);
                }
                if (app->render_finished_semaphores[j] != VK_NULL_HANDLE) {
                    vkDestroySemaphore(app->device, app->render_finished_semaphores[j], NULL);
                }
                if (app->in_flight_fences[j] != VK_NULL_HANDLE) {
                    vkDestroyFence(app->device, app->in_flight_fences[j], NULL);
                }
            }
            free(app->image_available_semaphores);
            free(app->render_finished_semaphores);
            free(app->in_flight_fences);
            app->image_available_semaphores = NULL;
            app->render_finished_semaphores = NULL;
            app->in_flight_fences = NULL;
            return -1;
        }
    }
    return 0;
}

static void destroy_swapchain_resources(App* app) {
    if (app->framebuffers) {
        for (uint32_t i = 0; i < app->swapchain_image_count; i++) {
            vkDestroyFramebuffer(app->device, app->framebuffers[i], NULL);
        }
        free(app->framebuffers);
        app->framebuffers = NULL;
    }

    if (app->command_buffers && app->command_pool && app->swapchain_image_count > 0) {
        vkFreeCommandBuffers(app->device, app->command_pool, app->swapchain_image_count, app->command_buffers);
        free(app->command_buffers);
        app->command_buffers = NULL;
    }

    if (app->image_available_semaphores || app->render_finished_semaphores || app->in_flight_fences) {
        for (uint32_t i = 0; i < app->swapchain_image_count; i++) {
            if (app->image_available_semaphores) {
                vkDestroySemaphore(app->device, app->image_available_semaphores[i], NULL);
            }
            if (app->render_finished_semaphores) {
                vkDestroySemaphore(app->device, app->render_finished_semaphores[i], NULL);
            }
            if (app->in_flight_fences) {
                vkDestroyFence(app->device, app->in_flight_fences[i], NULL);
            }
        }
    }

    if (app->image_available_semaphores) {
        free(app->image_available_semaphores);
        app->image_available_semaphores = NULL;
    }
    if (app->render_finished_semaphores) {
        free(app->render_finished_semaphores);
        app->render_finished_semaphores = NULL;
    }
    if (app->in_flight_fences) {
        free(app->in_flight_fences);
        app->in_flight_fences = NULL;
    }

    if (app->swapchain_image_views) {
        for (uint32_t i = 0; i < app->swapchain_image_count; i++) {
            vkDestroyImageView(app->device, app->swapchain_image_views[i], NULL);
        }
        free(app->swapchain_image_views);
        app->swapchain_image_views = NULL;
    }

    if (app->swapchain_images) {
        free(app->swapchain_images);
        app->swapchain_images = NULL;
    }

    if (app->swapchain) {
        vkDestroySwapchainKHR(app->device, app->swapchain, NULL);
        app->swapchain = VK_NULL_HANDLE;
    }

    app->swapchain_image_count = 0;
    app->current_frame = 0;
}

static int recreate_swapchain(App* app) {
    if (!app || !app->device) {
        fprintf(stderr, "recreate_swapchain: invalid app/device\n");
        return -1;
    }

    int pixel_width = 0;
    int pixel_height = 0;
    SDL_GetWindowSizeInPixels(app->window, &pixel_width, &pixel_height);
    if (pixel_width <= 0 || pixel_height <= 0) {
        return 1;
    }

    vkDeviceWaitIdle(app->device);
    destroy_swapchain_resources(app);
    if (app->render_pass) {
        vkDestroyRenderPass(app->device, app->render_pass, NULL);
        app->render_pass = VK_NULL_HANDLE;
    }

    if (create_swapchain(app) != 0) {
        fprintf(stderr, "recreate_swapchain: create_swapchain failed\n");
        return -1;
    }
    if (create_render_pass(app) != 0) {
        fprintf(stderr, "recreate_swapchain: create_render_pass failed\n");
        return -1;
    }
    if (create_framebuffers(app) != 0) {
        fprintf(stderr, "recreate_swapchain: create_framebuffers failed\n");
        return -1;
    }
    if (create_command_buffers(app) != 0) {
        fprintf(stderr, "recreate_swapchain: create_command_buffers failed\n");
        return -1;
    }
    if (create_sync_objects(app) != 0) {
        fprintf(stderr, "recreate_swapchain: create_sync_objects failed\n");
        return -1;
    }

    app->swapchain_needs_recreate = 0;
    app->current_frame = 0;
    if (app->swapchain_recreate_callback) {
        app->swapchain_recreate_callback(app->swapchain_recreate_userdata);
    }
    return 0;
}

int app_init(App* app, const char* title, int width, int height) {
    memset(app, 0, sizeof(App));
    app->graphics_queue_family = UINT32_MAX;

    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO)) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        goto fail;
    }

    app->width = width;
    app->height = height;
    app->running = 1;

    app->window = SDL_CreateWindow(title, width, height, SDL_WINDOW_VULKAN | SDL_WINDOW_RESIZABLE);
    if (!app->window) {
        fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        goto fail;
    }

    SDL_ShowWindow(app->window);
    SDL_GetWindowSizeInPixels(app->window, &app->width, &app->height);

    if (create_instance(app) != 0) {
        fprintf(stderr, "failed to create instance!\n");
        goto fail;
    }

    if (create_surface(app) != 0) {
        fprintf(stderr, "failed to create surface!\n");
        goto fail;
    }

    if (pick_physical_device(app) != 0) {
        fprintf(stderr, "failed to find a suitable GPU!\n");
        goto fail;
    }

    if (create_logical_device(app) != 0) {
        fprintf(stderr, "failed to create logical device!\n");
        goto fail;
    }

    if (create_swapchain(app) != 0) {
        fprintf(stderr, "failed to create swap chain!\n");
        goto fail;
    }

    if (create_render_pass(app) != 0) {
        fprintf(stderr, "failed to create render pass!\n");
        goto fail;
    }

    if (create_framebuffers(app) != 0) {
        fprintf(stderr, "failed to create framebuffers!\n");
        goto fail;
    }

    if (create_command_pool(app) != 0) {
        fprintf(stderr, "failed to create command pool!\n");
        goto fail;
    }

    if (create_command_buffers(app) != 0) {
        fprintf(stderr, "failed to create command buffers!\n");
        goto fail;
    }

    if (create_sync_objects(app) != 0) {
        fprintf(stderr, "failed to create sync objects!\n");
        goto fail;
    }

    app->current_frame = 0;
    printf("Vulkan window created successfully!\n");
    return 0;

fail:
    app_destroy(app);
    return -1;
}

void app_destroy(App* app) {
    if (app->device) {
        vkDeviceWaitIdle(app->device);
    }

    if (app->device) {
        destroy_swapchain_resources(app);
    }

    if (app->command_pool) vkDestroyCommandPool(app->device, app->command_pool, NULL);

    if (app->render_pass) vkDestroyRenderPass(app->device, app->render_pass, NULL);
    if (app->device) vkDestroyDevice(app->device, NULL);
    if (app->surface) vkDestroySurfaceKHR(app->instance, app->surface, NULL);
    if (app->instance) vkDestroyInstance(app->instance, NULL);

    if (app->window) SDL_DestroyWindow(app->window);
    SDL_Quit();
}

int app_poll_events(App* app) {
    SDL_Event event;
    while (SDL_PollEvent(&event)) {
        ui_process_event(&event);

        if (event.type == SDL_EVENT_QUIT) {
            app->running = 0;
            return 0;
        }
        if (event.type == SDL_EVENT_WINDOW_CLOSE_REQUESTED) {
            app->running = 0;
            return 0;
        }
        if (event.type == SDL_EVENT_KEY_DOWN) {
            if (event.key.key == SDLK_ESCAPE) {
                app->running = 0;
                return 0;
            }
        }
        if (event.type == SDL_EVENT_WINDOW_RESIZED) {
            SDL_GetWindowSizeInPixels(app->window, &app->width, &app->height);
            app->swapchain_needs_recreate = 1;
        }
    }
    return 1;
}

void app_set_render_callback(App* app, void (*callback)(void*), void* userdata) {
    app->render_callback = callback;
    app->render_userdata = userdata;
}

void app_set_swapchain_recreate_callback(App* app, void (*callback)(void*), void* userdata) {
    app->swapchain_recreate_callback = callback;
    app->swapchain_recreate_userdata = userdata;
}

void app_present(App* app) {
    if (app->swapchain_needs_recreate) {
        int recreate_result = recreate_swapchain(app);
        if (recreate_result != 0) {
            if (recreate_result < 0) {
                fprintf(stderr, "app_present: swapchain recreation failed\n");
            }
            return;
        }
    }

    if (app->swapchain_image_count == 0) {
        return;
    }

    if (vkWaitForFences(app->device, 1, &app->in_flight_fences[app->current_frame], VK_TRUE, UINT64_MAX) != VK_SUCCESS) {
        fprintf(stderr, "vkWaitForFences failed\n");
        return;
    }

    uint32_t image_index;
    VkResult result = vkAcquireNextImageKHR(app->device, app->swapchain, UINT64_MAX,
        app->image_available_semaphores[app->current_frame], VK_NULL_HANDLE, &image_index);

    if (result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR) {
        app->swapchain_needs_recreate = 1;
        recreate_swapchain(app);
        return;
    }
    if (result != VK_SUCCESS) {
        printf("vkAcquireNextImageKHR failed: %d\n", result);
        return;
    }

    if (vkResetCommandBuffer(app->command_buffers[app->current_frame], 0) != VK_SUCCESS) {
        fprintf(stderr, "vkResetCommandBuffer failed\n");
        return;
    }
    VkCommandBufferBeginInfo begin_info = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    if (vkBeginCommandBuffer(app->command_buffers[app->current_frame], &begin_info) != VK_SUCCESS) {
        fprintf(stderr, "vkBeginCommandBuffer failed\n");
        return;
    }

    VkRenderPassBeginInfo render_pass_info = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = app->render_pass,
        .framebuffer = app->framebuffers[image_index],
        .renderArea = {
            .offset = {0, 0},
            .extent = app->swapchain_extent,
        },
    };

    VkClearValue clear_color = {{{0.0f, 0.0f, 0.0f, 1.0f}}};
    render_pass_info.clearValueCount = 1;
    render_pass_info.pClearValues = &clear_color;

    vkCmdBeginRenderPass(app->command_buffers[app->current_frame], &render_pass_info, VK_SUBPASS_CONTENTS_INLINE);
    
    if (app->render_callback) {
        app->render_callback(app->render_userdata);
    }
    
    vkCmdEndRenderPass(app->command_buffers[app->current_frame]);

    if (vkEndCommandBuffer(app->command_buffers[app->current_frame]) != VK_SUCCESS) {
        return;
    }

    VkSubmitInfo submit_info = {};
    submit_info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;

    VkSemaphore wait_semaphores[] = {app->image_available_semaphores[app->current_frame]};
    VkPipelineStageFlags wait_stages[] = {VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
    submit_info.waitSemaphoreCount = 1;
    submit_info.pWaitSemaphores = wait_semaphores;
    submit_info.pWaitDstStageMask = wait_stages;
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &app->command_buffers[app->current_frame];

    VkSemaphore signal_semaphores[] = {app->render_finished_semaphores[app->current_frame]};
    submit_info.signalSemaphoreCount = 1;
    submit_info.pSignalSemaphores = signal_semaphores;

    if (vkResetFences(app->device, 1, &app->in_flight_fences[app->current_frame]) != VK_SUCCESS) {
        fprintf(stderr, "vkResetFences failed\n");
        return;
    }
    if (vkQueueSubmit(app->graphics_queue, 1, &submit_info, app->in_flight_fences[app->current_frame]) != VK_SUCCESS) {
        fprintf(stderr, "vkQueueSubmit failed\n");
        return;
    }

    VkPresentInfoKHR present_info = {};
    present_info.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
    present_info.waitSemaphoreCount = 1;
    present_info.pWaitSemaphores = signal_semaphores;

    VkSwapchainKHR swap_chains[] = {app->swapchain};
    present_info.swapchainCount = 1;
    present_info.pSwapchains = swap_chains;
    present_info.pImageIndices = &image_index;

    result = vkQueuePresentKHR(app->graphics_queue, &present_info);
    if (result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR) {
        app->swapchain_needs_recreate = 1;
        recreate_swapchain(app);
        return;
    }
    if (result != VK_SUCCESS) {
        printf("vkQueuePresentKHR failed: %d\n", result);
    }

    app->current_frame = (app->current_frame + 1) % app->swapchain_image_count;
}
