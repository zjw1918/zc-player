#include "audio_output.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define AUDIO_RING_MIN_SIZE 32768
#define AUDIO_CALLBACK_CHUNK_BYTES 4096
#define AUDIO_RING_SIZE_SECONDS 1
#define AUDIO_RING_TARGET_NUM 3
#define AUDIO_RING_TARGET_DEN 4
#define AUDIO_RING_RESUME_NUM 1
#define AUDIO_RING_RESUME_DEN 2

static size_t ring_read_locked(AudioOutput* output, uint8_t* dst, size_t len) {
    if (output->ring_used == 0 || len == 0) {
        return 0;
    }

    size_t to_read = len;
    if (to_read > output->ring_used) {
        to_read = output->ring_used;
    }

    size_t first = output->ring_size - output->ring_read_pos;
    if (first > to_read) {
        first = to_read;
    }

    memcpy(dst, output->ring_data + output->ring_read_pos, first);

    size_t second = to_read - first;
    if (second > 0) {
        memcpy(dst + first, output->ring_data, second);
    }

    output->ring_read_pos = (output->ring_read_pos + to_read) % output->ring_size;
    output->ring_used -= to_read;
    return to_read;
}

static void ring_write_locked(AudioOutput* output, const uint8_t* src, size_t len) {
    size_t first = output->ring_size - output->ring_write_pos;
    if (first > len) {
        first = len;
    }

    memcpy(output->ring_data + output->ring_write_pos, src, first);

    size_t second = len - first;
    if (second > 0) {
        memcpy(output->ring_data, src + first, second);
    }

    output->ring_write_pos = (output->ring_write_pos + len) % output->ring_size;
    output->ring_used += len;
}

static int audio_decode_thread_main(void* userdata) {
    AudioOutput* output = (AudioOutput*)userdata;
    int decode_throttled = 0;

    while (1) {
        SDL_LockMutex(output->ring_mutex);
        int running = output->decode_running;
        SDL_UnlockMutex(output->ring_mutex);

        if (!running) {
            break;
        }

        if (player_get_state(output->player) != PLAYER_STATE_PLAYING) {
            SDL_Delay(2);
            continue;
        }

        int stream_queued = SDL_GetAudioStreamQueued(output->stream);
        if (stream_queued < 0) {
            stream_queued = 0;
        }

        int should_decode = 1;
        SDL_LockMutex(output->ring_mutex);
        size_t buffered = output->ring_used + (size_t)stream_queued;
        if (output->ring_target_bytes > 0) {
            if (decode_throttled) {
                if (buffered > output->ring_resume_bytes) {
                    should_decode = 0;
                } else {
                    decode_throttled = 0;
                }
            } else if (buffered >= output->ring_target_bytes) {
                decode_throttled = 1;
                should_decode = 0;
            }
        }
        SDL_UnlockMutex(output->ring_mutex);

        if (!should_decode) {
            SDL_Delay(1);
            continue;
        }

        if (player_decode_audio(output->player) != 0) {
            SDL_Delay(1);
            continue;
        }

        uint8_t* samples = NULL;
        int nb_samples = 0;
        if (player_get_audio_samples(output->player, &samples, &nb_samples) != 0) {
            SDL_Delay(1);
            continue;
        }

        int bytes_remaining = nb_samples * output->bytes_per_frame;
        if (bytes_remaining <= 0 || !samples) {
            continue;
        }

        const uint8_t* src = samples;
        double pts = player_get_audio_pts(output->player);
        double frame_duration = 0.0;
        if (output->sample_rate > 0 && nb_samples > 0) {
            frame_duration = (double)nb_samples / (double)output->sample_rate;
        }

        SDL_LockMutex(output->ring_mutex);
        if (output->decode_running && output->clock_base_pts < 0.0 && pts >= 0.0) {
            if (!output->pts_offset_valid) {
                output->pts_offset = pts - output->expected_start_pts;
                output->pts_offset_valid = 1;
            }
            double adjusted_pts = pts - output->pts_offset;
            output->clock_base_pts = adjusted_pts;
            output->clock_base_time_ns = SDL_GetTicksNS();
        }

        if (output->decode_running && frame_duration > 0.0) {
            double frame_start = output->expected_start_pts;
            if (pts >= 0.0) {
                if (!output->pts_offset_valid) {
                    output->pts_offset = pts - output->expected_start_pts;
                    output->pts_offset_valid = 1;
                }
                frame_start = pts - output->pts_offset;
            }

            if (!output->decoded_end_valid) {
                output->decoded_end_pts = frame_start;
                output->decoded_end_valid = 1;
            } else if (frame_start < output->decoded_end_pts) {
                frame_start = output->decoded_end_pts;
            }

            output->decoded_end_pts = frame_start + frame_duration;
            output->clock_base_pts = output->decoded_end_pts;
        }

        while (output->decode_running && bytes_remaining > 0) {
            size_t writable = output->ring_size - output->ring_used;
            if (writable == 0) {
                SDL_WaitCondition(output->can_write, output->ring_mutex);
                continue;
            }

            size_t chunk = (size_t)bytes_remaining;
            if (chunk > writable) {
                chunk = writable;
            }

            ring_write_locked(output, src, chunk);
            src += chunk;
            bytes_remaining -= (int)chunk;
        }

        running = output->decode_running;
        SDL_UnlockMutex(output->ring_mutex);

        if (!running) {
            break;
        }
    }

    return 0;
}

static void audio_callback(void* userdata, SDL_AudioStream* stream, int additional_amount, int total_amount) {
    (void)total_amount;

    AudioOutput* output = (AudioOutput*)userdata;
    if (!output || !output->enabled || !output->device_opened || player_get_state(output->player) != PLAYER_STATE_PLAYING || additional_amount <= 0) {
        return;
    }

    uint8_t chunk[AUDIO_CALLBACK_CHUNK_BYTES];
    int remaining = additional_amount;

    while (remaining > 0) {
        int request = remaining;
        if (request > AUDIO_CALLBACK_CHUNK_BYTES) {
            request = AUDIO_CALLBACK_CHUNK_BYTES;
        }

        int got = 0;
        SDL_LockMutex(output->ring_mutex);
        if (output->ring_used > 0) {
            got = (int)ring_read_locked(output, chunk, (size_t)request);
            SDL_SignalCondition(output->can_write);
        }
        SDL_UnlockMutex(output->ring_mutex);

        if (got <= 0) {
            memset(chunk, 0, (size_t)request);
            if (!SDL_PutAudioStreamData(stream, chunk, request)) {
                break;
            }
            remaining -= request;
            continue;
        }

        if (!SDL_PutAudioStreamData(stream, chunk, got)) {
            break;
        }
        remaining -= got;
    }
}

int audio_output_init(AudioOutput* output, Player* player) {
    memset(output, 0, sizeof(AudioOutput));

    output->player = player;
    output->enabled = player_has_audio(player) ? 1 : 0;
    output->clock_base_pts = -1.0;
    output->playback_speed = player_get_playback_speed(player);
    output->expected_start_pts = player->current_time;

    if (!output->enabled) {
        return 0;
    }

    int channels = player_get_audio_channels(player);
    if (channels <= 0) {
        return -1;
    }

    output->sample_rate = player_get_audio_sample_rate(player);
    if (output->sample_rate <= 0) {
        output->sample_rate = 48000;
    }
    output->bytes_per_frame = channels * (int)sizeof(float);
    return 0;
}

int audio_output_start(AudioOutput* output) {
    if (!output->enabled) {
        return 0;
    }

    int sample_rate = output->sample_rate;
    int channels = player_get_audio_channels(output->player);

    size_t bytes_per_second = (size_t)sample_rate * (size_t)channels * sizeof(float);
    size_t ring_size = bytes_per_second * AUDIO_RING_SIZE_SECONDS;
    if (ring_size < AUDIO_RING_MIN_SIZE) {
        ring_size = AUDIO_RING_MIN_SIZE;
    }

    output->ring_data = malloc(ring_size);
    if (!output->ring_data) {
        return -1;
    }

    output->ring_size = ring_size;
    output->ring_read_pos = 0;
    output->ring_write_pos = 0;
    output->ring_used = 0;
    output->ring_target_bytes = (ring_size * AUDIO_RING_TARGET_NUM) / AUDIO_RING_TARGET_DEN;
    if (output->ring_target_bytes < (size_t)(AUDIO_CALLBACK_CHUNK_BYTES * 4)) {
        output->ring_target_bytes = (size_t)(AUDIO_CALLBACK_CHUNK_BYTES * 4);
    }
    if (output->ring_target_bytes > output->ring_size) {
        output->ring_target_bytes = output->ring_size;
    }
    output->ring_resume_bytes = (output->ring_target_bytes * AUDIO_RING_RESUME_NUM) / AUDIO_RING_RESUME_DEN;

    output->ring_mutex = SDL_CreateMutex();
    if (!output->ring_mutex) {
        audio_output_destroy(output);
        return -1;
    }

    output->can_write = SDL_CreateCondition();
    if (!output->can_write) {
        audio_output_destroy(output);
        return -1;
    }

    SDL_AudioSpec spec = {
        .freq = sample_rate,
        .format = SDL_AUDIO_F32LE,
        .channels = (Uint8)channels,
    };

    output->stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, audio_callback, output);
    if (!output->stream) {
        fprintf(stderr, "Failed to open audio stream: %s\n", SDL_GetError());
        audio_output_destroy(output);
        return -1;
    }

    SDL_SetAudioStreamGain(output->stream, (float)output->player->volume);
    SDL_SetAudioStreamFrequencyRatio(output->stream, (float)output->playback_speed);

    output->decode_running = 1;
    output->decode_thread = SDL_CreateThread(audio_decode_thread_main, "audio_decode", output);
    if (!output->decode_thread) {
        output->decode_running = 0;
        audio_output_destroy(output);
        return -1;
    }

    output->device_opened = 1;
    output->paused = 0;
    output->pause_started_ns = 0;
    output->paused_total_ns = 0;
    output->pts_offset_valid = 0;
    output->pts_offset = 0.0;
    output->decoded_end_valid = 0;
    output->decoded_end_pts = 0.0;
    if (!SDL_ResumeAudioStreamDevice(output->stream)) {
        fprintf(stderr, "Failed to resume audio stream device: %s\n", SDL_GetError());
    }
    return 0;
}

void audio_output_reset(AudioOutput* output) {
    if (!output || !output->enabled) {
        return;
    }

    if (output->stream) {
        SDL_ClearAudioStream(output->stream);
    }

    if (!output->ring_mutex) {
        return;
    }

    SDL_LockMutex(output->ring_mutex);
    output->ring_read_pos = 0;
    output->ring_write_pos = 0;
    output->ring_used = 0;
    output->clock_base_pts = -1.0;
    output->clock_base_time_ns = 0;
    output->expected_start_pts = output->player ? output->player->current_time : 0.0;
    output->pts_offset_valid = 0;
    output->pts_offset = 0.0;
    output->decoded_end_valid = 0;
    output->decoded_end_pts = 0.0;
    output->pause_started_ns = 0;
    output->paused_total_ns = 0;
    output->paused = 0;
    SDL_BroadcastCondition(output->can_write);
    SDL_UnlockMutex(output->ring_mutex);

    if (output->stream) {
        if (!SDL_ResumeAudioStreamDevice(output->stream)) {
            fprintf(stderr, "Failed to resume audio stream device: %s\n", SDL_GetError());
        }
    }
}

void audio_output_set_volume(AudioOutput* output, double volume) {
    if (!output || !output->enabled || !output->stream) {
        return;
    }

    if (volume < 0.0) {
        volume = 0.0;
    }
    if (volume > 1.0) {
        volume = 1.0;
    }

    SDL_SetAudioStreamGain(output->stream, (float)volume);
}

void audio_output_set_playback_speed(AudioOutput* output, double speed) {
    if (!output || !output->enabled || !output->stream) {
        return;
    }

    if (speed < 0.25) {
        speed = 0.25;
    }
    if (speed > 2.0) {
        speed = 2.0;
    }

    output->playback_speed = speed;
    SDL_SetAudioStreamFrequencyRatio(output->stream, (float)output->playback_speed);
}

void audio_output_set_paused(AudioOutput* output, int paused) {
    if (!output || !output->enabled || !output->stream || !output->ring_mutex) {
        return;
    }

    int target_paused = paused ? 1 : 0;
    Uint64 now_ns = SDL_GetTicksNS();

    SDL_LockMutex(output->ring_mutex);
    if (target_paused && !output->paused) {
        output->paused = 1;
        output->pause_started_ns = now_ns;
    } else if (!target_paused && output->paused) {
        if (output->pause_started_ns > 0 && now_ns > output->pause_started_ns) {
            output->paused_total_ns += (now_ns - output->pause_started_ns);
        }
        output->paused = 0;
        output->pause_started_ns = 0;
    }
    SDL_UnlockMutex(output->ring_mutex);

    int device_paused = SDL_AudioStreamDevicePaused(output->stream) ? 1 : 0;
    if (target_paused != device_paused) {
        int ok = target_paused ? SDL_PauseAudioStreamDevice(output->stream) : SDL_ResumeAudioStreamDevice(output->stream);
        if (!ok) {
            fprintf(stderr, "Failed to %s audio stream device: %s\n", target_paused ? "pause" : "resume", SDL_GetError());
        }
    }
}

void audio_output_destroy(AudioOutput* output) {
    if (output->decode_thread && output->ring_mutex) {
        SDL_LockMutex(output->ring_mutex);
        output->decode_running = 0;
        SDL_BroadcastCondition(output->can_write);
        SDL_UnlockMutex(output->ring_mutex);

        SDL_WaitThread(output->decode_thread, NULL);
        output->decode_thread = NULL;
    }

    output->decode_running = 0;
    output->paused = 0;
    output->pause_started_ns = 0;
    output->paused_total_ns = 0;
    output->sample_rate = 0;
    output->playback_speed = 1.0;

    if (output->stream) {
        SDL_DestroyAudioStream(output->stream);
        output->stream = NULL;
    }

    if (output->can_write) {
        SDL_DestroyCondition(output->can_write);
        output->can_write = NULL;
    }

    if (output->ring_mutex) {
        SDL_DestroyMutex(output->ring_mutex);
        output->ring_mutex = NULL;
    }

    if (output->ring_data) {
        free(output->ring_data);
        output->ring_data = NULL;
    }

    output->ring_size = 0;
    output->ring_read_pos = 0;
    output->ring_write_pos = 0;
    output->ring_used = 0;
    output->ring_target_bytes = 0;
    output->ring_resume_bytes = 0;
    output->device_opened = 0;
    output->clock_base_pts = -1.0;
    output->clock_base_time_ns = 0;
    output->pts_offset_valid = 0;
    output->pts_offset = 0.0;
    output->decoded_end_valid = 0;
    output->decoded_end_pts = 0.0;
}

int audio_output_get_master_clock(AudioOutput* output, double* out_clock) {
    if (!output || !out_clock || !output->enabled || !output->device_opened || !output->ring_mutex) {
        return -1;
    }

    SDL_LockMutex(output->ring_mutex);
    if (!output->decoded_end_valid) {
        SDL_UnlockMutex(output->ring_mutex);
        return -1;
    }

    double decoded_end_pts = output->decoded_end_pts;
    double expected_start_pts = output->expected_start_pts;
    size_t ring_used = output->ring_used;
    SDL_UnlockMutex(output->ring_mutex);

    int stream_queued = SDL_GetAudioStreamQueued(output->stream);
    if (stream_queued < 0) {
        stream_queued = 0;
    }

    double buffered_bytes = (double)stream_queued + (double)ring_used;
    double bytes_per_second = (double)output->bytes_per_frame * (double)output->sample_rate;
    if (bytes_per_second <= 0.0) {
        return -1;
    }

    double buffered_seconds = buffered_bytes / bytes_per_second;
    *out_clock = decoded_end_pts - buffered_seconds;
    if (*out_clock < expected_start_pts) {
        *out_clock = expected_start_pts;
    }
    return 0;
}
