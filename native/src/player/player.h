#ifndef CPLAYER_PLAYER_H
#define CPLAYER_PLAYER_H

#include <stdint.h>
#include "demuxer.h"
#include "video/video_decoder.h"
#include "audio/audio_decoder.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    PLAYER_STATE_STOPPED,
    PLAYER_STATE_PLAYING,
    PLAYER_STATE_PAUSED,
    PLAYER_STATE_BUFFERING,
} PlayerState;

typedef enum {
    PLAYER_COMMAND_PLAY,
    PLAYER_COMMAND_PAUSE,
    PLAYER_COMMAND_STOP,
    PLAYER_COMMAND_TOGGLE_PLAY_PAUSE,
} PlayerCommand;

typedef struct {
    char* filepath;
    PlayerState state;
    SDL_AtomicInt state_atomic;
    double current_time;
    double duration;
    double volume;
    double playback_speed;
    int width;
    int height;
    int eof;
    int seek_pending;
    double seek_target;
    SDL_Mutex* video_decode_mutex;
    SDL_Mutex* audio_decode_mutex;
    Demuxer demuxer;
    VideoDecoder decoder;
    AudioDecoder audio_decoder;
    int has_audio;
} Player;

int player_init(Player* player);
void player_destroy(Player* player);
int player_open(Player* player, const char* filepath);
int player_command(Player* player, PlayerCommand command);
PlayerState player_get_state(Player* player);
int player_has_media_loaded(Player* player);
void player_play(Player* player);
void player_pause(Player* player);
void player_stop(Player* player);
void player_seek(Player* player, double time);
int player_apply_seek(Player* player);
void player_set_volume(Player* player, double volume);
void player_set_playback_speed(Player* player, double speed);
double player_get_playback_speed(Player* player);
double player_get_time(Player* player);
int player_decode_frame(Player* player);
int player_get_video_frame(Player* player, uint8_t** data, int* linesize);
int player_get_video_format(Player* player);
double player_get_video_pts(Player* player);
int player_has_audio(Player* player);
int player_get_audio_sample_rate(Player* player);
int player_get_audio_channels(Player* player);
int player_decode_audio(Player* player);
int player_get_audio_samples(Player* player, uint8_t** data, int* nb_samples);
double player_get_audio_pts(Player* player);
void player_stop_demuxer(Player* player);

#ifdef __cplusplus
}
#endif

#endif
