#include "core/config.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static kl_binding_trigger_t key_trigger(kl_key_symbol_t key)
{
    return (kl_binding_trigger_t) {
        .kind = KL_BINDING_TRIGGER_KEY,
        .key = key,
    };
}

static kl_binding_trigger_t button_trigger(kl_binding_trigger_kind_t kind)
{
    return (kl_binding_trigger_t) {
        .kind = kind,
        .key = KL_KEY_SYMBOL_NONE,
    };
}

static bool add_binding(
    kl_config_t *config,
    kl_binding_trigger_t trigger,
    unsigned modifiers,
    kl_action_kind_t action,
    bool repeat,
    double cooldown_ms,
    const char *argument)
{
    if (config->binding_count == KL_CONFIG_MAX_BINDS) {
        return false;
    }

    kl_binding_t *binding = &config->bindings[config->binding_count++];
    memset(binding, 0, sizeof(*binding));
    binding->trigger = trigger;
    binding->modifiers = modifiers;
    binding->action = action;
    binding->repeat = repeat;
    binding->cooldown_ms = cooldown_ms;
    if (argument) {
        snprintf(binding->argument, sizeof(binding->argument), "%s", argument);
    }
    return true;
}

static bool add_window_rule(kl_config_t *config, const kl_window_rule_t *rule)
{
    if (rule->action == KL_WINDOW_RULE_ACTION_NONE ||
        config->window_rule_count == KL_CONFIG_MAX_WINDOW_RULES) {
        return false;
    }

    config->window_rules[config->window_rule_count++] = *rule;
    return true;
}

kl_config_t kl_config_default(void)
{
    kl_config_t config = {
        .layout = kl_layout_default_options(),
        .mod_modifier = KL_MODIFIER_ALT,
        .keyboard_scroll_fraction = 0.5,
        .scroll_wheel_sensitivity = 3.0,
        .gesture_scroll_sensitivity = 4.0,
        .gesture_scroll_inverted = true,
        .scroll_settle_delay = 0.08,
        .horizontal_view_animation_speed = 18.0,
        .focus_follows_mouse = true,
    };

    return config;
}

static char *trim(char *value)
{
    while (isspace((unsigned char) *value)) {
        value++;
    }

    char *end = value + strlen(value);
    while (end > value && isspace((unsigned char) end[-1])) {
        *--end = '\0';
    }

    return value;
}

static void strip_comments(char *line)
{
    bool quoted = false;
    bool escaped = false;

    for (char *cursor = line; *cursor; cursor++) {
        if (escaped) {
            escaped = false;
            continue;
        }

        if (*cursor == '\\' && quoted) {
            escaped = true;
            continue;
        }

        if (*cursor == '"') {
            quoted = !quoted;
            continue;
        }

        if (!quoted && *cursor == '#') {
            *cursor = '\0';
            return;
        }

        if (!quoted && cursor[0] == '/' && cursor[1] == '/') {
            *cursor = '\0';
            return;
        }
    }
}

static int brace_delta(const char *line)
{
    int delta = 0;
    bool quoted = false;
    bool escaped = false;

    for (const char *cursor = line; *cursor; cursor++) {
        if (escaped) {
            escaped = false;
            continue;
        }

        if (*cursor == '\\' && quoted) {
            escaped = true;
            continue;
        }

        if (*cursor == '"') {
            quoted = !quoted;
            continue;
        }

        if (!quoted && *cursor == '{') {
            delta++;
        } else if (!quoted && *cursor == '}') {
            delta--;
        }
    }

    return delta;
}

static bool parse_double(const char *value, double *out)
{
    errno = 0;
    char *end = NULL;
    double parsed = strtod(value, &end);

    if (errno != 0 || end == value) {
        return false;
    }

    end = trim(end);
    if (*end != '\0') {
        return false;
    }

    *out = parsed;
    return true;
}

static bool parse_bool(const char *value, bool *out)
{
    if (strcasecmp(value, "true") == 0 ||
        strcasecmp(value, "yes") == 0 ||
        strcmp(value, "1") == 0) {
        *out = true;
        return true;
    }

    if (strcasecmp(value, "false") == 0 ||
        strcasecmp(value, "no") == 0 ||
        strcmp(value, "0") == 0) {
        *out = false;
        return true;
    }

    return false;
}

static bool parse_center_mode(const char *value, kl_center_mode_t *out)
{
    if (strcmp(value, "never") == 0) {
        *out = KL_CENTER_NEVER;
        return true;
    }

    if (strcmp(value, "always") == 0) {
        *out = KL_CENTER_ALWAYS;
        return true;
    }

    if (strcmp(value, "on-overflow") == 0) {
        *out = KL_CENTER_ON_OVERFLOW;
        return true;
    }

    return false;
}

static void set_error(char *error, size_t error_size, size_t line, const char *message)
{
    if (error && error_size > 0) {
        snprintf(error, error_size, "line %zu: %s", line, message);
    }
}

static bool parse_mod_key(const char *value, unsigned *out)
{
    char buffer[64];
    snprintf(buffer, sizeof(buffer), "%s", value);
    char *parsed = trim(buffer);

    size_t length = strlen(parsed);
    if (length >= 2 && parsed[0] == '"' && parsed[length - 1] == '"') {
        parsed[length - 1] = '\0';
        parsed++;
    }
    length = strlen(parsed);
    if (length > 0 && parsed[length - 1] == ';') {
        parsed[length - 1] = '\0';
        parsed = trim(parsed);
    }

    if (strcasecmp(parsed, "alt") == 0 || strcasecmp(parsed, "option") == 0) {
        *out = KL_MODIFIER_ALT;
        return true;
    }

    if (strcasecmp(parsed, "super") == 0 ||
        strcasecmp(parsed, "win") == 0 ||
        strcasecmp(parsed, "cmd") == 0 ||
        strcasecmp(parsed, "command") == 0) {
        *out = KL_MODIFIER_SUPER;
        return true;
    }

    if (strcasecmp(parsed, "ctrl") == 0 || strcasecmp(parsed, "control") == 0) {
        *out = KL_MODIFIER_CTRL;
        return true;
    }

    if (strcasecmp(parsed, "shift") == 0) {
        *out = KL_MODIFIER_SHIFT;
        return true;
    }

    return false;
}

static bool parse_modifier(const char *token, const kl_config_t *config, unsigned *out)
{
    if (strcasecmp(token, "ctrl") == 0 || strcasecmp(token, "control") == 0) {
        *out = KL_MODIFIER_CTRL;
        return true;
    }

    if (strcasecmp(token, "shift") == 0) {
        *out = KL_MODIFIER_SHIFT;
        return true;
    }

    if (strcasecmp(token, "alt") == 0 || strcasecmp(token, "option") == 0) {
        *out = KL_MODIFIER_ALT;
        return true;
    }

    if (strcasecmp(token, "super") == 0 ||
        strcasecmp(token, "win") == 0 ||
        strcasecmp(token, "cmd") == 0 ||
        strcasecmp(token, "command") == 0) {
        *out = KL_MODIFIER_SUPER;
        return true;
    }

    if (strcasecmp(token, "mod") == 0) {
        *out = config->mod_modifier;
        return true;
    }

    return false;
}

static bool parse_key_symbol(const char *token, kl_key_symbol_t *out)
{
    if (strlen(token) == 1) {
        unsigned char ch = (unsigned char) token[0];
        if (isalpha(ch)) {
            *out = (kl_key_symbol_t) (KL_KEY_SYMBOL_A + (toupper(ch) - 'A'));
            return true;
        }
        if (isdigit(ch)) {
            *out = ch == '0'
                ? KL_KEY_SYMBOL_0
                : (kl_key_symbol_t) (KL_KEY_SYMBOL_1 + (ch - '1'));
            return true;
        }
    }

    struct key_name {
        const char *name;
        kl_key_symbol_t key;
    };

    static const struct key_name names[] = {
        {"Left", KL_KEY_SYMBOL_LEFT},
        {"Right", KL_KEY_SYMBOL_RIGHT},
        {"Up", KL_KEY_SYMBOL_UP},
        {"Down", KL_KEY_SYMBOL_DOWN},
        {"Home", KL_KEY_SYMBOL_HOME},
        {"End", KL_KEY_SYMBOL_END},
        {"Page_Up", KL_KEY_SYMBOL_PAGE_UP},
        {"PageUp", KL_KEY_SYMBOL_PAGE_UP},
        {"Page_Down", KL_KEY_SYMBOL_PAGE_DOWN},
        {"PageDown", KL_KEY_SYMBOL_PAGE_DOWN},
        {"Minus", KL_KEY_SYMBOL_MINUS},
        {"Equal", KL_KEY_SYMBOL_EQUAL},
        {"Equals", KL_KEY_SYMBOL_EQUAL},
        {"BracketLeft", KL_KEY_SYMBOL_BRACKET_LEFT},
        {"Bracket_Left", KL_KEY_SYMBOL_BRACKET_LEFT},
        {"BracketRight", KL_KEY_SYMBOL_BRACKET_RIGHT},
        {"Bracket_Right", KL_KEY_SYMBOL_BRACKET_RIGHT},
        {"Comma", KL_KEY_SYMBOL_COMMA},
        {"Period", KL_KEY_SYMBOL_PERIOD},
        {"Dot", KL_KEY_SYMBOL_PERIOD},
        {"Tab", KL_KEY_SYMBOL_TAB},
        {"Space", KL_KEY_SYMBOL_SPACE},
        {"Return", KL_KEY_SYMBOL_RETURN},
        {"Enter", KL_KEY_SYMBOL_RETURN},
        {"Escape", KL_KEY_SYMBOL_ESCAPE},
        {"Esc", KL_KEY_SYMBOL_ESCAPE},
    };

    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if (strcasecmp(token, names[i].name) == 0) {
            *out = names[i].key;
            return true;
        }
    }

    return false;
}

static bool parse_trigger_name(const char *token, kl_binding_trigger_t *trigger)
{
    struct trigger_name {
        const char *name;
        kl_binding_trigger_kind_t kind;
    };

    static const struct trigger_name triggers[] = {
        {"MouseLeft", KL_BINDING_TRIGGER_MOUSE_LEFT},
        {"MouseRight", KL_BINDING_TRIGGER_MOUSE_RIGHT},
        {"MouseMiddle", KL_BINDING_TRIGGER_MOUSE_MIDDLE},
        {"MouseBack", KL_BINDING_TRIGGER_MOUSE_BACK},
        {"MouseForward", KL_BINDING_TRIGGER_MOUSE_FORWARD},
        {"WheelScrollUp", KL_BINDING_TRIGGER_WHEEL_UP},
        {"WheelScrollDown", KL_BINDING_TRIGGER_WHEEL_DOWN},
        {"WheelScrollLeft", KL_BINDING_TRIGGER_WHEEL_LEFT},
        {"WheelScrollRight", KL_BINDING_TRIGGER_WHEEL_RIGHT},
        {"TouchpadScrollUp", KL_BINDING_TRIGGER_TOUCHPAD_UP},
        {"TouchpadScrollDown", KL_BINDING_TRIGGER_TOUCHPAD_DOWN},
        {"TouchpadScrollLeft", KL_BINDING_TRIGGER_TOUCHPAD_LEFT},
        {"TouchpadScrollRight", KL_BINDING_TRIGGER_TOUCHPAD_RIGHT},
    };

    for (size_t i = 0; i < sizeof(triggers) / sizeof(triggers[0]); i++) {
        if (strcasecmp(token, triggers[i].name) == 0) {
            *trigger = button_trigger(triggers[i].kind);
            return true;
        }
    }

    kl_key_symbol_t key = KL_KEY_SYMBOL_NONE;
    if (!parse_key_symbol(token, &key)) {
        return false;
    }

    *trigger = key_trigger(key);
    return true;
}

static bool parse_hotkey(
    char *value,
    const kl_config_t *config,
    kl_binding_trigger_t *trigger,
    unsigned *modifiers)
{
    *trigger = key_trigger(KL_KEY_SYMBOL_NONE);
    *modifiers = 0;

    bool has_trigger = false;
    char *save = NULL;
    for (char *part = strtok_r(value, "+", &save); part; part = strtok_r(NULL, "+", &save)) {
        part = trim(part);
        if (*part == '\0') {
            return false;
        }

        unsigned modifier = 0;
        if (parse_modifier(part, config, &modifier)) {
            *modifiers |= modifier;
            continue;
        }

        if (has_trigger || !parse_trigger_name(part, trigger)) {
            return false;
        }
        has_trigger = true;
    }

    return has_trigger;
}

static void remember_unsupported_bind(kl_config_t *config, const char *action)
{
    for (size_t i = 0; i < config->unsupported_bind_count; i++) {
        if (strcmp(config->unsupported_binds[i], action) == 0) {
            return;
        }
    }

    if (config->unsupported_bind_count == KL_CONFIG_MAX_UNSUPPORTED_BINDS) {
        return;
    }

    snprintf(
        config->unsupported_binds[config->unsupported_bind_count++],
        KL_CONFIG_BIND_ACTION_NAME_SIZE,
        "%s",
        action);
}

static bool parse_action_name(const char *name, kl_action_kind_t *out)
{
    if (strcmp(name, "scroll-left") == 0) {
        *out = KL_ACTION_SCROLL_LEFT;
    } else if (strcmp(name, "scroll-right") == 0) {
        *out = KL_ACTION_SCROLL_RIGHT;
    } else if (strcmp(name, "focus-column-left") == 0 ||
               strcmp(name, "focus-column-left-or-last") == 0 ||
               strcmp(name, "focus-column-or-monitor-left") == 0) {
        *out = KL_ACTION_FOCUS_COLUMN_LEFT;
    } else if (strcmp(name, "focus-column-right") == 0 ||
               strcmp(name, "focus-column-right-or-first") == 0 ||
               strcmp(name, "focus-column-or-monitor-right") == 0) {
        *out = KL_ACTION_FOCUS_COLUMN_RIGHT;
    } else if (strcmp(name, "focus-column-first") == 0) {
        *out = KL_ACTION_FOCUS_COLUMN_FIRST;
    } else if (strcmp(name, "focus-column-last") == 0) {
        *out = KL_ACTION_FOCUS_COLUMN_LAST;
    } else if (strcmp(name, "focus-window-up") == 0 ||
               strcmp(name, "focus-window-up-or-bottom") == 0 ||
               strcmp(name, "focus-window-up-or-column-left") == 0) {
        *out = KL_ACTION_FOCUS_WINDOW_UP;
    } else if (strcmp(name, "focus-window-down") == 0 ||
               strcmp(name, "focus-window-down-or-top") == 0 ||
               strcmp(name, "focus-window-down-or-column-right") == 0) {
        *out = KL_ACTION_FOCUS_WINDOW_DOWN;
    } else if (strcmp(name, "move-column-left") == 0 ||
               strcmp(name, "move-column-left-or-to-monitor-left") == 0) {
        *out = KL_ACTION_MOVE_COLUMN_LEFT;
    } else if (strcmp(name, "move-column-right") == 0 ||
               strcmp(name, "move-column-right-or-to-monitor-right") == 0) {
        *out = KL_ACTION_MOVE_COLUMN_RIGHT;
    } else if (strcmp(name, "move-column-to-first") == 0) {
        *out = KL_ACTION_MOVE_COLUMN_FIRST;
    } else if (strcmp(name, "move-column-to-last") == 0) {
        *out = KL_ACTION_MOVE_COLUMN_LAST;
    } else if (strcmp(name, "move-window-up") == 0) {
        *out = KL_ACTION_MOVE_WINDOW_UP;
    } else if (strcmp(name, "move-window-down") == 0) {
        *out = KL_ACTION_MOVE_WINDOW_DOWN;
    } else if (strcmp(name, "toggle-window-floating") == 0 ||
               strcmp(name, "toggle-floating") == 0) {
        *out = KL_ACTION_TOGGLE_WINDOW_FLOATING;
    } else if (strcmp(name, "move-window-to-floating") == 0) {
        *out = KL_ACTION_MOVE_WINDOW_TO_FLOATING;
    } else if (strcmp(name, "move-window-to-tiling") == 0) {
        *out = KL_ACTION_MOVE_WINDOW_TO_TILING;
    } else if (strcmp(name, "maximize-column") == 0 ||
               strcmp(name, "maximize-window-to-edges") == 0) {
        *out = KL_ACTION_MAXIMIZE_COLUMN;
    } else if (strcmp(name, "set-column-width") == 0 ||
               strcmp(name, "set-window-width") == 0) {
        *out = KL_ACTION_SET_COLUMN_WIDTH;
    } else if (strcmp(name, "start-interactive-move") == 0 ||
               strcmp(name, "interactive-move") == 0 ||
               strcmp(name, "move-window") == 0) {
        *out = KL_ACTION_START_MOVE;
    } else if (strcmp(name, "start-interactive-resize") == 0 ||
               strcmp(name, "interactive-resize") == 0 ||
               strcmp(name, "resize-window") == 0 ||
               strcmp(name, "resize-column") == 0) {
        *out = KL_ACTION_START_RESIZE;
    } else {
        return false;
    }

    return true;
}

static bool parse_action_body(
    char *body,
    kl_config_t *config,
    kl_action_kind_t *action,
    char *argument,
    size_t argument_size)
{
    char *semicolon = strrchr(body, ';');
    if (semicolon) {
        *semicolon = '\0';
    }

    body = trim(body);
    if (*body == '\0') {
        return false;
    }

    char *name_end = body;
    while (*name_end && !isspace((unsigned char) *name_end)) {
        name_end++;
    }

    char action_name[KL_CONFIG_BIND_ACTION_NAME_SIZE];
    size_t action_name_length = (size_t) (name_end - body);
    if (action_name_length == 0 || action_name_length >= sizeof(action_name)) {
        return false;
    }
    memcpy(action_name, body, action_name_length);
    action_name[action_name_length] = '\0';

    if (!parse_action_name(action_name, action)) {
        remember_unsupported_bind(config, action_name);
        return false;
    }

    argument[0] = '\0';
    char *rest = trim(name_end);
    if (*rest == '\0') {
        return true;
    }

    if (*rest == '"') {
        rest++;
        char *end = rest;
        bool escaped = false;
        while (*end) {
            if (escaped) {
                escaped = false;
            } else if (*end == '\\') {
                escaped = true;
            } else if (*end == '"') {
                break;
            }
            end++;
        }
        size_t length = (size_t) (end - rest);
        if (length >= argument_size) {
            length = argument_size - 1;
        }
        memcpy(argument, rest, length);
        argument[length] = '\0';
    } else {
        char *end = rest;
        while (*end && !isspace((unsigned char) *end)) {
            end++;
        }
        size_t length = (size_t) (end - rest);
        if (length >= argument_size) {
            length = argument_size - 1;
        }
        memcpy(argument, rest, length);
        argument[length] = '\0';
    }

    return true;
}

static char *strip_kdl_value(char *value)
{
    value = trim(value);
    size_t length = strlen(value);
    if (length > 0 && value[length - 1] == ';') {
        value[--length] = '\0';
        value = trim(value);
    }

    length = strlen(value);
    if (length >= 2 && value[0] == '"' && value[length - 1] == '"') {
        value[length - 1] = '\0';
        value++;
    }

    return value;
}

static void parse_window_rule_match_property(
    kl_window_rule_t *rule,
    bool *supported,
    const char *key,
    const char *value)
{
    if (strcmp(key, "role") == 0) {
        snprintf(rule->role, sizeof(rule->role), "%s", value);
    } else if (strcmp(key, "subrole") == 0) {
        snprintf(rule->subrole, sizeof(rule->subrole), "%s", value);
    } else if (strcmp(key, "app-id") == 0) {
        snprintf(rule->app_id, sizeof(rule->app_id), "%s", value);
    } else if (strcmp(key, "app-name") == 0) {
        snprintf(rule->app_name, sizeof(rule->app_name), "%s", value);
    } else {
        *supported = false;
    }
}

static bool parse_bind_line(
    kl_config_t *config,
    char *line,
    char *error,
    size_t error_size,
    size_t line_number)
{
    char *open = strchr(line, '{');
    char *close = strrchr(line, '}');
    if (!open || !close || close < open) {
        set_error(error, error_size, line_number, "expected one-line bind: Hotkey { action; }");
        return false;
    }

    *open = '\0';
    *close = '\0';
    char *prefix = trim(line);
    char *body = trim(open + 1);

    char *hotkey_end = prefix;
    while (*hotkey_end && !isspace((unsigned char) *hotkey_end)) {
        hotkey_end++;
    }

    char hotkey[128];
    size_t hotkey_length = (size_t) (hotkey_end - prefix);
    if (hotkey_length == 0 || hotkey_length >= sizeof(hotkey)) {
        set_error(error, error_size, line_number, "invalid bind hotkey");
        return false;
    }
    memcpy(hotkey, prefix, hotkey_length);
    hotkey[hotkey_length] = '\0';

    kl_binding_trigger_t trigger;
    unsigned modifiers = 0;
    if (!parse_hotkey(hotkey, config, &trigger, &modifiers)) {
        set_error(error, error_size, line_number, "invalid bind hotkey");
        return false;
    }

    bool repeat = true;
    double cooldown_ms = 0.0;
    char *property_save = NULL;
    for (char *property = strtok_r(hotkey_end, " \t\r\n", &property_save);
         property;
         property = strtok_r(NULL, " \t\r\n", &property_save)) {
        char *equals = strchr(property, '=');
        if (!equals) {
            continue;
        }
        *equals = '\0';
        char *key = property;
        char *value = equals + 1;
        bool boolean = false;
        double number = 0.0;

        if (strcmp(key, "repeat") == 0) {
            if (!parse_bool(value, &boolean)) {
                set_error(error, error_size, line_number, "invalid bind repeat property");
                return false;
            }
            repeat = boolean;
        } else if (strcmp(key, "cooldown-ms") == 0) {
            if (!parse_double(value, &number) || number < 0.0) {
                set_error(error, error_size, line_number, "invalid bind cooldown-ms property");
                return false;
            }
            cooldown_ms = number;
        }
    }

    kl_action_kind_t action;
    char argument[KL_CONFIG_BIND_ARGUMENT_SIZE];
    if (!parse_action_body(body, config, &action, argument, sizeof(argument))) {
        return true;
    }

    if (!add_binding(config, trigger, modifiers, action, repeat, cooldown_ms, argument)) {
        set_error(error, error_size, line_number, "too many binds");
        return false;
    }

    return true;
}

static bool parse_window_rule_match_line(
    kl_window_rule_t *rule,
    bool *supported,
    char *line,
    char *error,
    size_t error_size,
    size_t line_number)
{
    (void) error;
    (void) error_size;
    (void) line_number;

    char *cursor = trim(line + 5);

    while (*cursor) {
        while (isspace((unsigned char) *cursor)) {
            cursor++;
        }
        if (*cursor == '\0' || *cursor == '}') {
            break;
        }

        char key[64];
        size_t key_length = 0;
        while (*cursor &&
               *cursor != '=' &&
               !isspace((unsigned char) *cursor) &&
               key_length + 1 < sizeof(key)) {
            key[key_length++] = *cursor++;
        }
        key[key_length] = '\0';

        while (isspace((unsigned char) *cursor)) {
            cursor++;
        }
        if (*cursor != '=') {
            while (*cursor && !isspace((unsigned char) *cursor)) {
                cursor++;
            }
            continue;
        }
        cursor++;
        while (isspace((unsigned char) *cursor)) {
            cursor++;
        }

        char value[KL_CONFIG_WINDOW_RULE_MATCH_SIZE];
        size_t value_length = 0;
        if (*cursor == '"') {
            cursor++;
            bool escaped = false;
            while (*cursor) {
                if (escaped) {
                    if (value_length + 1 < sizeof(value)) {
                        value[value_length++] = *cursor;
                    }
                    escaped = false;
                } else if (*cursor == '\\') {
                    escaped = true;
                } else if (*cursor == '"') {
                    cursor++;
                    break;
                } else if (value_length + 1 < sizeof(value)) {
                    value[value_length++] = *cursor;
                }
                cursor++;
            }
        } else {
            while (*cursor &&
                   !isspace((unsigned char) *cursor) &&
                   *cursor != ';' &&
                   *cursor != '}' &&
                   value_length + 1 < sizeof(value)) {
                value[value_length++] = *cursor++;
            }
        }
        value[value_length] = '\0';

        if (key[0] != '\0') {
            parse_window_rule_match_property(rule, supported, key, value);
        }
    }

    return true;
}

static bool parse_window_rule_bool_node(
    char *line,
    const char *name,
    bool *out)
{
    size_t name_length = strlen(name);
    if (strncmp(line, name, name_length) != 0 ||
        (line[name_length] != '\0' && !isspace((unsigned char) line[name_length]) && line[name_length] != '=')) {
        return false;
    }

    char *value = trim(line + name_length);
    if (*value == '=') {
        value = trim(value + 1);
    }

    if (*value == '\0' || strcmp(value, ";") == 0) {
        *out = true;
        return true;
    }

    value = strip_kdl_value(value);
    return parse_bool(value, out);
}

static bool parse_window_rule_line(
    kl_window_rule_t *rule,
    bool *supported,
    char *line,
    char *error,
    size_t error_size,
    size_t line_number)
{
    char *trimmed = trim(line);
    if (*trimmed == '\0') {
        return true;
    }

    if (strncmp(trimmed, "match", 5) == 0 &&
        (trimmed[5] == '\0' || isspace((unsigned char) trimmed[5]))) {
        return parse_window_rule_match_line(rule, supported, trimmed, error, error_size, line_number);
    }

    bool value = false;
    if (parse_window_rule_bool_node(trimmed, "open-floating", &value)) {
        rule->action = value ? KL_WINDOW_RULE_ACTION_FLOATING : KL_WINDOW_RULE_ACTION_TILED;
        return true;
    }

    if (parse_window_rule_bool_node(trimmed, "open-tiled", &value)) {
        rule->action = value ? KL_WINDOW_RULE_ACTION_TILED : KL_WINDOW_RULE_ACTION_NONE;
        return true;
    }

    if (parse_window_rule_bool_node(trimmed, "ignore", &value) ||
        parse_window_rule_bool_node(trimmed, "open-ignored", &value)) {
        rule->action = value ? KL_WINDOW_RULE_ACTION_IGNORED : KL_WINDOW_RULE_ACTION_NONE;
        return true;
    }

    if (parse_window_rule_bool_node(trimmed, "manage", &value)) {
        rule->action = value ? KL_WINDOW_RULE_ACTION_TILED : KL_WINDOW_RULE_ACTION_IGNORED;
        return true;
    }

    return true;
}

static bool parse_input_line(
    kl_config_t *config,
    char *line,
    char *error,
    size_t error_size,
    size_t line_number)
{
    char *trimmed = trim(line);
    if (*trimmed == '\0' || strcmp(trimmed, "}") == 0) {
        return true;
    }

    if (strncmp(trimmed, "mod-key", 7) != 0 ||
        (trimmed[7] != '\0' && !isspace((unsigned char) trimmed[7]) && trimmed[7] != '=')) {
        return true;
    }

    char *value = trimmed + 7;
    value = trim(value);
    if (*value == '=') {
        value = trim(value + 1);
    }

    unsigned modifier = 0;
    if (!parse_mod_key(value, &modifier)) {
        set_error(error, error_size, line_number, "invalid input mod-key");
        return false;
    }

    config->mod_modifier = modifier;
    return true;
}

static bool parse_key_value(
    kl_config_t *config,
    char *key,
    char *value,
    char *error,
    size_t error_size,
    size_t line_number)
{
    double number = 0.0;
    bool boolean = false;

    if (strcmp(key, "default-width-fraction") == 0 ||
        strcmp(key, "default-column-width") == 0 ||
        strcmp(key, "default-column-width-proportion") == 0) {
        if (!parse_double(value, &number) || number <= 0.0) {
            set_error(error, error_size, line_number, "invalid default column width proportion");
            return false;
        }
        config->layout.default_width_fraction = number;
    } else if (strcmp(key, "gap") == 0 || strcmp(key, "gaps") == 0) {
        if (!parse_double(value, &number) || number < 0.0) {
            set_error(error, error_size, line_number, "invalid gaps");
            return false;
        }
        config->layout.gap = number;
    } else if (strcmp(key, "padding") == 0) {
        if (!parse_double(value, &number) || number < 0.0) {
            set_error(error, error_size, line_number, "invalid padding");
            return false;
        }
        config->layout.padding_left = number;
        config->layout.padding_right = number;
        config->layout.padding_top = number;
        config->layout.padding_bottom = number;
    } else if (strcmp(key, "padding-left") == 0) {
        if (!parse_double(value, &number) || number < 0.0) {
            set_error(error, error_size, line_number, "invalid padding-left");
            return false;
        }
        config->layout.padding_left = number;
    } else if (strcmp(key, "padding-right") == 0) {
        if (!parse_double(value, &number) || number < 0.0) {
            set_error(error, error_size, line_number, "invalid padding-right");
            return false;
        }
        config->layout.padding_right = number;
    } else if (strcmp(key, "padding-top") == 0) {
        if (!parse_double(value, &number) || number < 0.0) {
            set_error(error, error_size, line_number, "invalid padding-top");
            return false;
        }
        config->layout.padding_top = number;
    } else if (strcmp(key, "padding-bottom") == 0) {
        if (!parse_double(value, &number) || number < 0.0) {
            set_error(error, error_size, line_number, "invalid padding-bottom");
            return false;
        }
        config->layout.padding_bottom = number;
    } else if (strcmp(key, "keyboard-scroll-fraction") == 0) {
        if (!parse_double(value, &number) || number <= 0.0) {
            set_error(error, error_size, line_number, "invalid keyboard-scroll-fraction");
            return false;
        }
        config->keyboard_scroll_fraction = number;
    } else if (strcmp(key, "scroll-wheel-sensitivity") == 0) {
        if (!parse_double(value, &number) || number <= 0.0) {
            set_error(error, error_size, line_number, "invalid scroll-wheel-sensitivity");
            return false;
        }
        config->scroll_wheel_sensitivity = number;
    } else if (strcmp(key, "gesture-scroll-sensitivity") == 0) {
        if (!parse_double(value, &number) || number <= 0.0) {
            set_error(error, error_size, line_number, "invalid gesture-scroll-sensitivity");
            return false;
        }
        config->gesture_scroll_sensitivity = number;
    } else if (strcmp(key, "gesture-scroll-inverted") == 0 ||
               strcmp(key, "invert-gesture-scroll") == 0) {
        if (!parse_bool(value, &boolean)) {
            set_error(error, error_size, line_number, "invalid gesture-scroll-inverted");
            return false;
        }
        config->gesture_scroll_inverted = boolean;
    } else if (strcmp(key, "scroll-settle-delay") == 0) {
        if (!parse_double(value, &number) || number < 0.01) {
            set_error(error, error_size, line_number, "invalid scroll-settle-delay");
            return false;
        }
        config->scroll_settle_delay = number;
    } else if (strcmp(key, "horizontal-view-animation-speed") == 0 ||
               strcmp(key, "animation-speed") == 0) {
        if (!parse_double(value, &number) || number <= 0.0) {
            set_error(error, error_size, line_number, "invalid horizontal-view-animation-speed");
            return false;
        }
        config->horizontal_view_animation_speed = number;
    } else if (strcmp(key, "center-focused-column") == 0) {
        if (!parse_center_mode(value, &config->layout.center_mode)) {
            set_error(error, error_size, line_number, "invalid center-focused-column");
            return false;
        }
    } else if (strcmp(key, "always-center-single-column") == 0) {
        if (!parse_bool(value, &boolean)) {
            set_error(error, error_size, line_number, "invalid always-center-single-column");
            return false;
        }
        config->layout.always_center_single_column = boolean;
    } else if (strcmp(key, "focus-follows-mouse") == 0) {
        if (!parse_bool(value, &boolean)) {
            set_error(error, error_size, line_number, "invalid focus-follows-mouse");
            return false;
        }
        config->focus_follows_mouse = boolean;
    } else if (strcmp(key, "mod-key") == 0) {
        unsigned modifier = 0;
        if (!parse_mod_key(value, &modifier)) {
            set_error(error, error_size, line_number, "invalid mod-key");
            return false;
        }
        config->mod_modifier = modifier;
    } else {
        set_error(error, error_size, line_number, "unknown key");
        return false;
    }

    return true;
}

typedef enum config_block {
    CONFIG_BLOCK_NONE,
    CONFIG_BLOCK_BINDS,
    CONFIG_BLOCK_INPUT,
    CONFIG_BLOCK_WINDOW_RULE,
    CONFIG_BLOCK_SKIP,
} config_block_t;

bool kl_config_load_file(const char *path, kl_config_t *config, char *error, size_t error_size)
{
    FILE *file = fopen(path, "r");
    if (!file) {
        if (error && error_size > 0) {
            snprintf(error, error_size, "%s: %s", path, strerror(errno));
        }
        return false;
    }

    char line_buffer[1024];
    size_t line_number = 0;
    config_block_t block = CONFIG_BLOCK_NONE;
    int skip_depth = 0;
    bool saw_binds_block = false;
    kl_window_rule_t pending_window_rule;
    bool pending_window_rule_supported = true;
    memset(&pending_window_rule, 0, sizeof(pending_window_rule));

    while (fgets(line_buffer, sizeof(line_buffer), file)) {
        line_number++;
        strip_comments(line_buffer);
        char *line = trim(line_buffer);
        if (*line == '\0') {
            continue;
        }

        if (block == CONFIG_BLOCK_SKIP) {
            skip_depth += brace_delta(line);
            if (skip_depth <= 0) {
                block = CONFIG_BLOCK_NONE;
            }
            continue;
        }

        if (block == CONFIG_BLOCK_INPUT) {
            if (!parse_input_line(config, line, error, error_size, line_number)) {
                fclose(file);
                return false;
            }
            if (strchr(line, '}')) {
                block = CONFIG_BLOCK_NONE;
            }
            continue;
        }

        if (block == CONFIG_BLOCK_BINDS) {
            if (strcmp(line, "}") == 0) {
                block = CONFIG_BLOCK_NONE;
                continue;
            }

            if (strchr(line, '{')) {
                if (!parse_bind_line(config, line, error, error_size, line_number)) {
                    fclose(file);
                    return false;
                }
            }

            if (strchr(line, '}') && !strchr(line, '{')) {
                block = CONFIG_BLOCK_NONE;
            }
            continue;
        }

        if (block == CONFIG_BLOCK_WINDOW_RULE) {
            if (strcmp(line, "}") == 0) {
                if (pending_window_rule_supported) {
                    add_window_rule(config, &pending_window_rule);
                }
                memset(&pending_window_rule, 0, sizeof(pending_window_rule));
                pending_window_rule_supported = true;
                block = CONFIG_BLOCK_NONE;
                continue;
            }

            if (!parse_window_rule_line(
                    &pending_window_rule,
                    &pending_window_rule_supported,
                    line,
                    error,
                    error_size,
                    line_number)) {
                fclose(file);
                return false;
            }

            if (strchr(line, '}')) {
                if (pending_window_rule_supported) {
                    add_window_rule(config, &pending_window_rule);
                }
                memset(&pending_window_rule, 0, sizeof(pending_window_rule));
                pending_window_rule_supported = true;
                block = CONFIG_BLOCK_NONE;
            }
            continue;
        }

        char *open = strchr(line, '{');
        if (open) {
            char section[64];
            size_t section_length = (size_t) (open - line);
            while (section_length > 0 && isspace((unsigned char) line[section_length - 1])) {
                section_length--;
            }
            if (section_length >= sizeof(section)) {
                section_length = sizeof(section) - 1;
            }
            memcpy(section, line, section_length);
            section[section_length] = '\0';

            if (strcmp(section, "binds") == 0) {
                if (!saw_binds_block) {
                    config->binding_count = 0;
                    config->unsupported_bind_count = 0;
                    config->custom_binds = true;
                    saw_binds_block = true;
                }
                block = CONFIG_BLOCK_BINDS;
                continue;
            }

            if (strcmp(section, "input") == 0) {
                block = CONFIG_BLOCK_INPUT;
                continue;
            }

            if (strcmp(section, "window-rule") == 0) {
                memset(&pending_window_rule, 0, sizeof(pending_window_rule));
                pending_window_rule_supported = true;
                block = CONFIG_BLOCK_WINDOW_RULE;
                continue;
            }

            block = CONFIG_BLOCK_SKIP;
            skip_depth = brace_delta(line);
            if (skip_depth <= 0) {
                block = CONFIG_BLOCK_NONE;
            }
            continue;
        }

        char *separator = strchr(line, '=');
        if (!separator) {
            continue;
        }

        *separator = '\0';
        char *key = trim(line);
        char *value = trim(separator + 1);
        if (!parse_key_value(config, key, value, error, error_size, line_number)) {
            fclose(file);
            return false;
        }
    }

    fclose(file);
    return true;
}

static bool trigger_equals(kl_binding_trigger_t left, kl_binding_trigger_t right)
{
    return left.kind == right.kind && left.key == right.key;
}

kl_binding_t *kl_config_find_binding(
    kl_config_t *config,
    kl_binding_trigger_t trigger,
    unsigned modifiers)
{
    unsigned mask =
        KL_MODIFIER_CTRL |
        KL_MODIFIER_SHIFT |
        KL_MODIFIER_ALT |
        KL_MODIFIER_SUPER;
    modifiers &= mask;

    for (size_t i = 0; i < config->binding_count; i++) {
        kl_binding_t *binding = &config->bindings[i];
        if ((binding->modifiers & mask) == modifiers &&
            trigger_equals(binding->trigger, trigger)) {
            return binding;
        }
    }

    return NULL;
}

const char *kl_action_name(kl_action_kind_t action)
{
    switch (action) {
    case KL_ACTION_SCROLL_LEFT:
        return "scroll-left";
    case KL_ACTION_SCROLL_RIGHT:
        return "scroll-right";
    case KL_ACTION_FOCUS_COLUMN_LEFT:
        return "focus-column-left";
    case KL_ACTION_FOCUS_COLUMN_RIGHT:
        return "focus-column-right";
    case KL_ACTION_FOCUS_COLUMN_FIRST:
        return "focus-column-first";
    case KL_ACTION_FOCUS_COLUMN_LAST:
        return "focus-column-last";
    case KL_ACTION_FOCUS_WINDOW_UP:
        return "focus-window-up";
    case KL_ACTION_FOCUS_WINDOW_DOWN:
        return "focus-window-down";
    case KL_ACTION_MOVE_COLUMN_LEFT:
        return "move-column-left";
    case KL_ACTION_MOVE_COLUMN_RIGHT:
        return "move-column-right";
    case KL_ACTION_MOVE_COLUMN_FIRST:
        return "move-column-to-first";
    case KL_ACTION_MOVE_COLUMN_LAST:
        return "move-column-to-last";
    case KL_ACTION_MOVE_WINDOW_UP:
        return "move-window-up";
    case KL_ACTION_MOVE_WINDOW_DOWN:
        return "move-window-down";
    case KL_ACTION_TOGGLE_WINDOW_FLOATING:
        return "toggle-window-floating";
    case KL_ACTION_MOVE_WINDOW_TO_FLOATING:
        return "move-window-to-floating";
    case KL_ACTION_MOVE_WINDOW_TO_TILING:
        return "move-window-to-tiling";
    case KL_ACTION_MAXIMIZE_COLUMN:
        return "maximize-column";
    case KL_ACTION_SET_COLUMN_WIDTH:
        return "set-column-width";
    case KL_ACTION_START_MOVE:
        return "start-interactive-move";
    case KL_ACTION_START_RESIZE:
        return "start-interactive-resize";
    }

    return "unknown";
}
