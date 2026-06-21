#ifndef KLOTSKI_CORE_CONFIG_H
#define KLOTSKI_CORE_CONFIG_H

#include <stdbool.h>
#include <stddef.h>

#include "layout/strip.h"

#define KL_CONFIG_MAX_BINDS 192
#define KL_CONFIG_MAX_UNSUPPORTED_BINDS 128
#define KL_CONFIG_MAX_WINDOW_RULES 64
#define KL_CONFIG_BIND_ARGUMENT_SIZE 96
#define KL_CONFIG_BIND_ACTION_NAME_SIZE 64
#define KL_CONFIG_WINDOW_RULE_MATCH_SIZE 64

typedef enum kl_modifier {
    KL_MODIFIER_CTRL = 1 << 0,
    KL_MODIFIER_SHIFT = 1 << 1,
    KL_MODIFIER_ALT = 1 << 2,
    KL_MODIFIER_SUPER = 1 << 3,
} kl_modifier_t;

typedef enum kl_key_symbol {
    KL_KEY_SYMBOL_NONE,
    KL_KEY_SYMBOL_A,
    KL_KEY_SYMBOL_B,
    KL_KEY_SYMBOL_C,
    KL_KEY_SYMBOL_D,
    KL_KEY_SYMBOL_E,
    KL_KEY_SYMBOL_F,
    KL_KEY_SYMBOL_G,
    KL_KEY_SYMBOL_H,
    KL_KEY_SYMBOL_I,
    KL_KEY_SYMBOL_J,
    KL_KEY_SYMBOL_K,
    KL_KEY_SYMBOL_L,
    KL_KEY_SYMBOL_M,
    KL_KEY_SYMBOL_N,
    KL_KEY_SYMBOL_O,
    KL_KEY_SYMBOL_P,
    KL_KEY_SYMBOL_Q,
    KL_KEY_SYMBOL_R,
    KL_KEY_SYMBOL_S,
    KL_KEY_SYMBOL_T,
    KL_KEY_SYMBOL_U,
    KL_KEY_SYMBOL_V,
    KL_KEY_SYMBOL_W,
    KL_KEY_SYMBOL_X,
    KL_KEY_SYMBOL_Y,
    KL_KEY_SYMBOL_Z,
    KL_KEY_SYMBOL_1,
    KL_KEY_SYMBOL_2,
    KL_KEY_SYMBOL_3,
    KL_KEY_SYMBOL_4,
    KL_KEY_SYMBOL_5,
    KL_KEY_SYMBOL_6,
    KL_KEY_SYMBOL_7,
    KL_KEY_SYMBOL_8,
    KL_KEY_SYMBOL_9,
    KL_KEY_SYMBOL_0,
    KL_KEY_SYMBOL_LEFT,
    KL_KEY_SYMBOL_RIGHT,
    KL_KEY_SYMBOL_UP,
    KL_KEY_SYMBOL_DOWN,
    KL_KEY_SYMBOL_HOME,
    KL_KEY_SYMBOL_END,
    KL_KEY_SYMBOL_PAGE_UP,
    KL_KEY_SYMBOL_PAGE_DOWN,
    KL_KEY_SYMBOL_MINUS,
    KL_KEY_SYMBOL_EQUAL,
    KL_KEY_SYMBOL_BRACKET_LEFT,
    KL_KEY_SYMBOL_BRACKET_RIGHT,
    KL_KEY_SYMBOL_COMMA,
    KL_KEY_SYMBOL_PERIOD,
    KL_KEY_SYMBOL_TAB,
    KL_KEY_SYMBOL_SPACE,
    KL_KEY_SYMBOL_RETURN,
    KL_KEY_SYMBOL_ESCAPE,
} kl_key_symbol_t;

typedef enum kl_binding_trigger_kind {
    KL_BINDING_TRIGGER_KEY,
    KL_BINDING_TRIGGER_MOUSE_LEFT,
    KL_BINDING_TRIGGER_MOUSE_RIGHT,
    KL_BINDING_TRIGGER_MOUSE_MIDDLE,
    KL_BINDING_TRIGGER_MOUSE_BACK,
    KL_BINDING_TRIGGER_MOUSE_FORWARD,
    KL_BINDING_TRIGGER_WHEEL_UP,
    KL_BINDING_TRIGGER_WHEEL_DOWN,
    KL_BINDING_TRIGGER_WHEEL_LEFT,
    KL_BINDING_TRIGGER_WHEEL_RIGHT,
    KL_BINDING_TRIGGER_TOUCHPAD_UP,
    KL_BINDING_TRIGGER_TOUCHPAD_DOWN,
    KL_BINDING_TRIGGER_TOUCHPAD_LEFT,
    KL_BINDING_TRIGGER_TOUCHPAD_RIGHT,
} kl_binding_trigger_kind_t;

typedef struct kl_binding_trigger {
    kl_binding_trigger_kind_t kind;
    kl_key_symbol_t key;
} kl_binding_trigger_t;

typedef enum kl_action_kind {
    KL_ACTION_SCROLL_LEFT,
    KL_ACTION_SCROLL_RIGHT,
    KL_ACTION_FOCUS_COLUMN_LEFT,
    KL_ACTION_FOCUS_COLUMN_RIGHT,
    KL_ACTION_FOCUS_COLUMN_FIRST,
    KL_ACTION_FOCUS_COLUMN_LAST,
    KL_ACTION_FOCUS_WINDOW_UP,
    KL_ACTION_FOCUS_WINDOW_DOWN,
    KL_ACTION_MOVE_COLUMN_LEFT,
    KL_ACTION_MOVE_COLUMN_RIGHT,
    KL_ACTION_MOVE_COLUMN_FIRST,
    KL_ACTION_MOVE_COLUMN_LAST,
    KL_ACTION_MOVE_WINDOW_UP,
    KL_ACTION_MOVE_WINDOW_DOWN,
    KL_ACTION_TOGGLE_WINDOW_FLOATING,
    KL_ACTION_MOVE_WINDOW_TO_FLOATING,
    KL_ACTION_MOVE_WINDOW_TO_TILING,
    KL_ACTION_MAXIMIZE_COLUMN,
    KL_ACTION_SET_COLUMN_WIDTH,
    KL_ACTION_START_MOVE,
    KL_ACTION_START_RESIZE,
} kl_action_kind_t;

typedef struct kl_binding {
    kl_binding_trigger_t trigger;
    unsigned modifiers;
    kl_action_kind_t action;
    bool repeat;
    double cooldown_ms;
    double last_triggered_at;
    char argument[KL_CONFIG_BIND_ARGUMENT_SIZE];
} kl_binding_t;

typedef enum kl_window_rule_action {
    KL_WINDOW_RULE_ACTION_NONE,
    KL_WINDOW_RULE_ACTION_TILED,
    KL_WINDOW_RULE_ACTION_FLOATING,
    KL_WINDOW_RULE_ACTION_IGNORED,
} kl_window_rule_action_t;

typedef struct kl_window_rule {
    char role[KL_CONFIG_WINDOW_RULE_MATCH_SIZE];
    char subrole[KL_CONFIG_WINDOW_RULE_MATCH_SIZE];
    char app_id[KL_CONFIG_WINDOW_RULE_MATCH_SIZE];
    char app_name[KL_CONFIG_WINDOW_RULE_MATCH_SIZE];
    kl_window_rule_action_t action;
} kl_window_rule_t;

typedef struct kl_config {
    kl_layout_options_t layout;
    unsigned mod_modifier;
    double keyboard_scroll_fraction;
    double scroll_wheel_sensitivity;
    double gesture_scroll_sensitivity;
    bool gesture_scroll_inverted;
    double scroll_settle_delay;
    double horizontal_view_animation_speed;
    bool focus_follows_mouse;
    bool custom_binds;
    kl_binding_t bindings[KL_CONFIG_MAX_BINDS];
    size_t binding_count;
    kl_window_rule_t window_rules[KL_CONFIG_MAX_WINDOW_RULES];
    size_t window_rule_count;
    char unsupported_binds[KL_CONFIG_MAX_UNSUPPORTED_BINDS][KL_CONFIG_BIND_ACTION_NAME_SIZE];
    size_t unsupported_bind_count;
} kl_config_t;

kl_config_t kl_config_default(void);
bool kl_config_load_file(const char *path, kl_config_t *config, char *error, size_t error_size);
kl_binding_t *kl_config_find_binding(
    kl_config_t *config,
    kl_binding_trigger_t trigger,
    unsigned modifiers);
const char *kl_action_name(kl_action_kind_t action);

#endif
