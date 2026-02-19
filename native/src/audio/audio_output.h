#ifndef CPLAYER_AUDIO_OUTPUT_H
#define CPLAYER_AUDIO_OUTPUT_H

#include <SDL3/SDL.h>
#include <stdint.h>
#include "player/player.h"

typedef struct {
    Player* player;
    int enabled;
    int device_opened;

    SDL_AudioStream* stream;
    SDL_Thread* decode_thread;
    int decode_running;
    int paused;
    Uint64 pause_started_ns;
    Uint64 paused_total_ns;

    int sample_rate;
    int bytes_per_frame;
    double playback_speed;
    uint8_t* ring_data;
    size_t ring_size;
    size_t ring_read_pos;
    size_t ring_write_pos;
    size_t ring_used;
    size_t ring_target_bytes;
    size_t ring_resume_bytes;
    SDL_Mutex* ring_mutex;
    SDL_Condition* can_write;

    double clock_base_pts;
    Uint64 clock_base_time_ns;
    double expected_start_pts;
    double pts_offset;
    int pts_offset_valid;
    double decoded_end_pts;
    int decoded_end_valid;
} AudioOutput;

int audio_output_init(AudioOutput* output, Player* player);
int audio_output_start(AudioOutput* output);
void audio_output_reset(AudioOutput* output);
void audio_output_set_volume(AudioOutput* output, double volume);
void audio_output_set_playback_speed(AudioOutput* output, double speed);
void audio_output_set_paused(AudioOutput* output, int paused);
void audio_output_destroy(AudioOutput* output);
int audio_output_get_master_clock(AudioOutput* output, double* out_clock);

#endif
