#ifndef KLOTSKI_PLATFORM_MACOS_WINDOW_SERVER_H
#define KLOTSKI_PLATFORM_MACOS_WINDOW_SERVER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include <ApplicationServices/ApplicationServices.h>

#include "layout/geometry.h"

#define KL_MACOS_MAX_WINDOWS 512

typedef struct kl_macos_window {
    uint32_t window_id;
    pid_t pid;
    kl_rect_t frame;
} kl_macos_window_t;

typedef struct kl_macos_window_hints {
    bool fullscreen_known;
    bool fullscreen;
    char role[64];
    char subrole[64];
    char app_id[64];
    char app_name[64];
} kl_macos_window_hints_t;

typedef struct kl_macos_window_list {
    kl_macos_window_t windows[KL_MACOS_MAX_WINDOWS];
    size_t count;
} kl_macos_window_list_t;

typedef struct kl_macos_window_frame_cache_entry {
    uint32_t window_id;
    pid_t pid;
    AXUIElementRef ax_window;
    kl_rect_t last_frame;
    kl_rect_t last_visible_frame;
    bool has_last_frame;
    bool has_last_visible_frame;
    bool hidden;
    bool has_hidden_state;
} kl_macos_window_frame_cache_entry_t;

typedef struct kl_macos_window_frame_cache {
    kl_macos_window_frame_cache_entry_t entries[KL_MACOS_MAX_WINDOWS];
    size_t count;
} kl_macos_window_frame_cache_t;

bool kl_macos_copy_window_list(kl_macos_window_list_t *out, pid_t only_pid);
bool kl_macos_find_window(const kl_macos_window_list_t *list, uint32_t window_id, kl_macos_window_t *out);
bool kl_macos_copy_window_hints(const kl_macos_window_t *window, kl_macos_window_hints_t *out);
bool kl_macos_copy_window_from_ax_element(
    pid_t pid,
    AXUIElementRef ax_window,
    kl_macos_window_t *out,
    kl_macos_window_hints_t *hints);
bool kl_macos_copy_window_identity_from_ax_element(
    pid_t pid,
    AXUIElementRef ax_window,
    kl_macos_window_t *out);
bool kl_macos_window_at_point(kl_point_t point, pid_t only_pid, kl_macos_window_t *out);
bool kl_macos_focus_window(const kl_macos_window_t *window);
bool kl_macos_set_window_frame(const kl_macos_window_t *window, kl_rect_t frame);
bool kl_macos_copy_window_frame(const kl_macos_window_t *window, kl_rect_t *out);
bool kl_macos_begin_frame_updates(void);
void kl_macos_end_frame_updates(bool active);
void kl_macos_window_frame_cache_init(kl_macos_window_frame_cache_t *cache);
void kl_macos_window_frame_cache_destroy(kl_macos_window_frame_cache_t *cache);
void kl_macos_window_frame_cache_prune(
    kl_macos_window_frame_cache_t *cache,
    const kl_macos_window_list_t *live_windows);
void kl_macos_window_frame_cache_forget(
    kl_macos_window_frame_cache_t *cache,
    uint32_t window_id);
bool kl_macos_window_frame_cache_needs_frame(
    const kl_macos_window_frame_cache_t *cache,
    const kl_macos_window_t *window,
    kl_rect_t frame);
bool kl_macos_window_frame_cache_matches_width(
    const kl_macos_window_frame_cache_t *cache,
    const kl_macos_window_t *window,
    kl_rect_t frame);
bool kl_macos_window_frame_cache_set_hidden(
    kl_macos_window_frame_cache_t *cache,
    const kl_macos_window_t *window,
    bool hidden);
size_t kl_macos_window_frame_cache_restore_hidden_except(
    kl_macos_window_frame_cache_t *cache,
    const uint32_t *window_ids,
    size_t window_id_count,
    size_t *failed);
void kl_macos_window_frame_cache_remember_ax_window(
    kl_macos_window_frame_cache_t *cache,
    const kl_macos_window_t *window,
    AXUIElementRef ax_window);
void kl_macos_window_frame_cache_note_frame(
    kl_macos_window_frame_cache_t *cache,
    const kl_macos_window_t *window,
    kl_rect_t frame);
bool kl_macos_set_window_frame_cached(
    kl_macos_window_frame_cache_t *cache,
    const kl_macos_window_t *window,
    kl_rect_t frame,
    bool *wrote_frame);

#endif
