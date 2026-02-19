#include "player.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int player_has_media_internal(const Player* player) {
    return player && player->demuxer.fmt_ctx && player->width > 0 && player->height > 0;
}

static void player_set_state(Player* player, PlayerState state) {
    if (!player) {
        return;
    }
    player->state = state;
    SDL_SetAtomicInt(&player->state_atomic, (int)state);
}

static int player_can_transition(Player* player, PlayerState from, PlayerState to) {
    if (!player) {
        return 0;
    }

    if (to != PLAYER_STATE_STOPPED && !player_has_media_internal(player)) {
        return 0;
    }

    switch (from) {
        case PLAYER_STATE_STOPPED:
            return to == PLAYER_STATE_STOPPED || to == PLAYER_STATE_PLAYING;
        case PLAYER_STATE_PLAYING:
            return to == PLAYER_STATE_PLAYING || to == PLAYER_STATE_PAUSED || to == PLAYER_STATE_STOPPED || to == PLAYER_STATE_BUFFERING;
        case PLAYER_STATE_PAUSED:
            return to == PLAYER_STATE_PAUSED || to == PLAYER_STATE_PLAYING || to == PLAYER_STATE_STOPPED || to == PLAYER_STATE_BUFFERING;
        case PLAYER_STATE_BUFFERING:
            return to == PLAYER_STATE_BUFFERING || to == PLAYER_STATE_PLAYING || to == PLAYER_STATE_PAUSED || to == PLAYER_STATE_STOPPED;
    }

    return 0;
}

static int player_transition(Player* player, PlayerState to) {
    if (!player) {
        return -1;
    }

    PlayerState from = player_get_state(player);
    if (!player_can_transition(player, from, to)) {
        return -1;
    }

    if (to == PLAYER_STATE_STOPPED) {
        player->current_time = 0.0;
        player->eof = 0;
        player->seek_pending = 1;
        player->seek_target = 0.0;
    } else if (to == PLAYER_STATE_PLAYING) {
        player->eof = 0;
    }

    if (from != to) {
        player_set_state(player, to);
    }

    return 0;
}

static void player_close_media(Player* player) {
    video_decoder_destroy(&player->decoder);
    if (player->has_audio) {
        audio_decoder_destroy(&player->audio_decoder);
    }
    demuxer_close(&player->demuxer);
    player->has_audio = 0;
    player->width = 0;
    player->height = 0;
}

int player_init(Player* player) {
    memset(player, 0, sizeof(Player));
    player->video_decode_mutex = SDL_CreateMutex();
    if (!player->video_decode_mutex) {
        return -1;
    }
    player->audio_decode_mutex = SDL_CreateMutex();
    if (!player->audio_decode_mutex) {
        SDL_DestroyMutex(player->video_decode_mutex);
        player->video_decode_mutex = NULL;
        return -1;
    }
    player_set_state(player, PLAYER_STATE_STOPPED);
    player->volume = 1.0;
    player->playback_speed = 1.0;
    return 0;
}

void player_destroy(Player* player) {
    if (!player) {
        return;
    }

    player_close_media(player);

    if (player->filepath) {
        free(player->filepath);
        player->filepath = NULL;
    }

    if (player->video_decode_mutex) {
        SDL_DestroyMutex(player->video_decode_mutex);
        player->video_decode_mutex = NULL;
    }

    if (player->audio_decode_mutex) {
        SDL_DestroyMutex(player->audio_decode_mutex);
        player->audio_decode_mutex = NULL;
    }
}

int player_open(Player* player, const char* filepath) {
    if (!player || !filepath) {
        return -1;
    }

    player_close_media(player);

    if (player->filepath) {
        free(player->filepath);
        player->filepath = NULL;
    }

    player->filepath = strdup(filepath);
    if (!player->filepath) {
        return -1;
    }

    printf("Opening video: %s\n", filepath);
    fflush(stdout);

    if (demuxer_open(&player->demuxer, filepath) != 0) {
        fprintf(stderr, "Failed to open demuxer\n");
        goto fail;
    }

    if (video_decoder_init(&player->decoder, player->demuxer.video_stream) != 0) {
        fprintf(stderr, "Failed to init video decoder\n");
        goto fail;
    }

    player->width = player->decoder.width;
    player->height = player->decoder.height;

    if (player->demuxer.audio_stream && audio_decoder_init(&player->audio_decoder, player->demuxer.audio_stream) == 0) {
        player->has_audio = 1;
        printf("Audio stream found: %d channels, %d Hz\n",
               player->audio_decoder.channels, player->audio_decoder.sample_rate);
    } else {
        player->has_audio = 0;
        if (player->demuxer.audio_stream) {
            fprintf(stderr, "Audio stream available but decoder init failed\n");
        } else {
            printf("No audio stream available\n");
        }
    }

    if (demuxer_start(&player->demuxer) != 0) {
        fprintf(stderr, "Failed to start demuxer thread\n");
        goto fail;
    }

    player_set_state(player, PLAYER_STATE_STOPPED);
    player->current_time = 0;
    if (player->demuxer.fmt_ctx && player->demuxer.fmt_ctx->duration > 0) {
        player->duration = (double)player->demuxer.fmt_ctx->duration / (double)AV_TIME_BASE;
    } else {
        player->duration = 0;
    }
    player->eof = 0;
    player->seek_pending = 0;
    player->seek_target = 0.0;

    printf("Player opened: %s (%dx%d)\n", filepath, player->width, player->height);
    return 0;

fail:
    player_close_media(player);
    player_set_state(player, PLAYER_STATE_STOPPED);
    return -1;
}

int player_command(Player* player, PlayerCommand command) {
    if (!player) {
        return -1;
    }

    switch (command) {
        case PLAYER_COMMAND_PLAY:
            return player_transition(player, PLAYER_STATE_PLAYING);
        case PLAYER_COMMAND_PAUSE:
            return player_transition(player, PLAYER_STATE_PAUSED);
        case PLAYER_COMMAND_STOP:
            return player_transition(player, PLAYER_STATE_STOPPED);
        case PLAYER_COMMAND_TOGGLE_PLAY_PAUSE: {
            PlayerState state = player_get_state(player);
            if (state == PLAYER_STATE_PLAYING) {
                return player_transition(player, PLAYER_STATE_PAUSED);
            }
            return player_transition(player, PLAYER_STATE_PLAYING);
        }
    }

    return -1;
}

PlayerState player_get_state(Player* player) {
    if (!player) {
        return PLAYER_STATE_STOPPED;
    }
    return (PlayerState)SDL_GetAtomicInt(&player->state_atomic);
}

int player_has_media_loaded(Player* player) {
    return player_has_media_internal(player);
}

void player_play(Player* player) {
    (void)player_command(player, PLAYER_COMMAND_PLAY);
}

void player_pause(Player* player) {
    (void)player_command(player, PLAYER_COMMAND_PAUSE);
}

void player_stop(Player* player) {
    (void)player_command(player, PLAYER_COMMAND_STOP);
}

void player_seek(Player* player, double time) {
    if (!player) {
        return;
    }

    if (time < 0.0) {
        time = 0.0;
    }
    if (player->duration > 0.0 && time > player->duration) {
        time = player->duration;
    }

    player->seek_pending = 1;
    player->seek_target = time;
}

int player_apply_seek(Player* player) {
    if (!player || !player->seek_pending) {
        return 0;
    }

    if (player->video_decode_mutex) {
        SDL_LockMutex(player->video_decode_mutex);
    }
    if (player->audio_decode_mutex) {
        SDL_LockMutex(player->audio_decode_mutex);
    }

    double target = player->seek_target;
    int result = -1;
    if (demuxer_seek(&player->demuxer, target) == 0) {
        video_decoder_flush(&player->decoder);
        player->decoder.pts = target;
        if (player->has_audio) {
            audio_decoder_flush(&player->audio_decoder);
            player->audio_decoder.pts = target;
        }
        player->current_time = target;
        player->eof = 0;
        player->seek_pending = 0;
        result = 0;
    } else {
        player->seek_pending = 0;
    }

    if (player->audio_decode_mutex) {
        SDL_UnlockMutex(player->audio_decode_mutex);
    }
    if (player->video_decode_mutex) {
        SDL_UnlockMutex(player->video_decode_mutex);
    }

    return result;
}

void player_set_volume(Player* player, double volume) {
    player->volume = volume > 1.0 ? 1.0 : (volume < 0.0 ? 0.0 : volume);
}

void player_set_playback_speed(Player* player, double speed) {
    if (!player) {
        return;
    }

    if (speed < 0.25) {
        speed = 0.25;
    }
    if (speed > 2.0) {
        speed = 2.0;
    }
    player->playback_speed = speed;
}

double player_get_playback_speed(Player* player) {
    if (!player) {
        return 1.0;
    }
    if (player->playback_speed <= 0.0) {
        return 1.0;
    }
    return player->playback_speed;
}

double player_get_time(Player* player) {
    return player->current_time;
}

int player_decode_frame(Player* player) {
    if (player_get_state(player) != PLAYER_STATE_PLAYING) {
        return -1;
    }

    if (player->video_decode_mutex) {
        SDL_LockMutex(player->video_decode_mutex);
    }
    int ret = video_decoder_decode_frame(&player->decoder, &player->demuxer);
    if (player->video_decode_mutex) {
        SDL_UnlockMutex(player->video_decode_mutex);
    }
    return ret;
}

int player_get_video_frame(Player* player, uint8_t** data, int* linesize) {
    return video_decoder_get_image(&player->decoder, data, linesize);
}

double player_get_video_pts(Player* player) {
    return player->decoder.pts;
}

int player_has_audio(Player* player) {
    return player->has_audio;
}

int player_get_audio_sample_rate(Player* player) {
    if (!player->has_audio) {
        return 0;
    }
    return player->audio_decoder.sample_rate;
}

int player_get_audio_channels(Player* player) {
    if (!player->has_audio) {
        return 0;
    }
    return player->audio_decoder.channels;
}

int player_decode_audio(Player* player) {
    if (!player->has_audio) {
        return -1;
    }
    if (player_get_state(player) != PLAYER_STATE_PLAYING) {
        return -1;
    }
    if (player->audio_decode_mutex) {
        SDL_LockMutex(player->audio_decode_mutex);
    }
    int ret = audio_decoder_decode_frame(&player->audio_decoder, &player->demuxer);
    if (player->audio_decode_mutex) {
        SDL_UnlockMutex(player->audio_decode_mutex);
    }
    return ret;
}

int player_get_audio_samples(Player* player, uint8_t** data, int* nb_samples) {
    if (!player->has_audio) {
        return -1;
    }
    return audio_decoder_get_samples(&player->audio_decoder, data, nb_samples);
}

double player_get_audio_pts(Player* player) {
    if (!player->has_audio) {
        return 0.0;
    }
    return player->audio_decoder.pts;
}
