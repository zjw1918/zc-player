#ifndef CPLAYER_APP_H
#define CPLAYER_APP_H

#include <SDL3/SDL.h>
#include <vulkan/vulkan.h>

#define MAX_FRAMES_IN_FLIGHT 2

typedef struct {
    SDL_Window* window;
    VkInstance instance;
    VkSurfaceKHR surface;
    VkPhysicalDevice gpu;
    VkDevice device;
    VkQueue graphics_queue;
    uint32_t graphics_queue_family;
    int portability_subset_supported;
    VkSwapchainKHR swapchain;
    VkFormat swapchain_format;
    VkExtent2D swapchain_extent;
    VkImage* swapchain_images;
    uint32_t swapchain_image_count;
    VkImageView* swapchain_image_views;
    VkRenderPass render_pass;
    VkFramebuffer* framebuffers;
    VkCommandPool command_pool;
    VkCommandBuffer* command_buffers;
    VkSemaphore* image_available_semaphores;
    VkSemaphore* render_finished_semaphores;
    VkFence* in_flight_fences;
    uint32_t current_frame;
    int width;
    int height;
    int running;
    int swapchain_needs_recreate;
    void (*render_callback)(void*);
    void* render_userdata;
    void (*swapchain_recreate_callback)(void*);
    void* swapchain_recreate_userdata;
} App;

void app_set_render_callback(App* app, void (*callback)(void*), void* userdata);
void app_set_swapchain_recreate_callback(App* app, void (*callback)(void*), void* userdata);

int app_init(App* app, const char* title, int width, int height);
void app_destroy(App* app);
int app_poll_events(App* app);
void app_present(App* app);

#endif
