#ifndef COCKPIT_GHOSTTY_H
#define COCKPIT_GHOSTTY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

#if defined(_WIN32)
#define COCKPIT_GHOSTTY_API __declspec(dllexport)
#else
#define COCKPIT_GHOSTTY_API __attribute__((visibility("default")))
#endif

typedef struct cockpit_ghostty_vt cockpit_ghostty_vt_t;
typedef struct cockpit_ghostty_renderer cockpit_ghostty_renderer_t;
typedef struct {
  const uint8_t *bytes;
  size_t length;
} cockpit_ghostty_bytes_t;

typedef enum {
  COCKPIT_GHOSTTY_MOD_SHIFT = 1u << 0,
  COCKPIT_GHOSTTY_MOD_CONTROL = 1u << 1,
  COCKPIT_GHOSTTY_MOD_ALT = 1u << 2,
  COCKPIT_GHOSTTY_MOD_SUPER = 1u << 3,
  COCKPIT_GHOSTTY_MOD_CAPS_LOCK = 1u << 4,
  COCKPIT_GHOSTTY_MOD_NUM_LOCK = 1u << 5,
  COCKPIT_GHOSTTY_MOD_SHIFT_RIGHT = 1u << 6,
  COCKPIT_GHOSTTY_MOD_CONTROL_RIGHT = 1u << 7,
  COCKPIT_GHOSTTY_MOD_ALT_RIGHT = 1u << 8,
  COCKPIT_GHOSTTY_MOD_SUPER_RIGHT = 1u << 9
} cockpit_ghostty_modifiers_t;
typedef enum {
  COCKPIT_GHOSTTY_KEY_PRESS = 1,
  COCKPIT_GHOSTTY_KEY_REPEAT = 2,
  COCKPIT_GHOSTTY_KEY_RELEASE = 3
} cockpit_ghostty_key_action_t;
typedef enum {
  COCKPIT_GHOSTTY_MOUSE_PRESS = 1,
  COCKPIT_GHOSTTY_MOUSE_RELEASE = 2,
  COCKPIT_GHOSTTY_MOUSE_MOTION = 3,
  COCKPIT_GHOSTTY_MOUSE_SCROLL = 4
} cockpit_ghostty_mouse_action_t;
typedef struct {
  uint32_t logical_key;
  uint32_t physical_key;
  uint32_t modifiers;
  uint8_t action;
  uint8_t reserved[3];
} cockpit_ghostty_key_event_t;
typedef struct {
  int32_t cell_x;
  int32_t cell_y;
  uint32_t buttons;
  int32_t wheel_x;
  int32_t wheel_y;
  uint32_t modifiers;
  uint8_t action;
  uint8_t reserved[3];
} cockpit_ghostty_mouse_event_t;

COCKPIT_GHOSTTY_API cockpit_ghostty_vt_t *cockpit_ghostty_vt_create(
    uint32_t columns, uint32_t rows, uint64_t scrollback_limit);
COCKPIT_GHOSTTY_API void cockpit_ghostty_vt_destroy(cockpit_ghostty_vt_t *);
COCKPIT_GHOSTTY_API int cockpit_ghostty_vt_feed(
    cockpit_ghostty_vt_t *, const uint8_t *, size_t);
COCKPIT_GHOSTTY_API int cockpit_ghostty_vt_resize(
    cockpit_ghostty_vt_t *, uint32_t, uint32_t);
COCKPIT_GHOSTTY_API int cockpit_ghostty_vt_snapshot(
    cockpit_ghostty_vt_t *, cockpit_ghostty_bytes_t *);
COCKPIT_GHOSTTY_API int cockpit_ghostty_vt_delta(
    cockpit_ghostty_vt_t *, uint64_t, cockpit_ghostty_bytes_t *);
COCKPIT_GHOSTTY_API int cockpit_ghostty_vt_scrollback(
    cockpit_ghostty_vt_t *, uint64_t, uint32_t, cockpit_ghostty_bytes_t *);
COCKPIT_GHOSTTY_API int cockpit_ghostty_vt_encode_key(
    cockpit_ghostty_vt_t *, const cockpit_ghostty_key_event_t *,
    cockpit_ghostty_bytes_t *);
COCKPIT_GHOSTTY_API int cockpit_ghostty_vt_encode_paste(
    cockpit_ghostty_vt_t *, const uint8_t *, size_t, cockpit_ghostty_bytes_t *);
COCKPIT_GHOSTTY_API int cockpit_ghostty_vt_encode_mouse(
    cockpit_ghostty_vt_t *, const cockpit_ghostty_mouse_event_t *,
    cockpit_ghostty_bytes_t *);
COCKPIT_GHOSTTY_API void cockpit_ghostty_vt_reset_input_state(
    cockpit_ghostty_vt_t *);
COCKPIT_GHOSTTY_API void cockpit_ghostty_bytes_free(cockpit_ghostty_bytes_t);

COCKPIT_GHOSTTY_API cockpit_ghostty_renderer_t *cockpit_ghostty_renderer_create(
    void *ns_view, double scale);
COCKPIT_GHOSTTY_API void cockpit_ghostty_renderer_destroy(
    cockpit_ghostty_renderer_t *);
COCKPIT_GHOSTTY_API int cockpit_ghostty_renderer_apply(
    cockpit_ghostty_renderer_t *, const uint8_t *, size_t);
COCKPIT_GHOSTTY_API int cockpit_ghostty_renderer_resize(
    cockpit_ghostty_renderer_t *, uint32_t pixels_w, uint32_t pixels_h,
    double scale);
COCKPIT_GHOSTTY_API int cockpit_ghostty_renderer_set_visible(
    cockpit_ghostty_renderer_t *, bool);

#if defined(__cplusplus)
}
#endif

#endif
