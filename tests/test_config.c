#include "core/config.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void write_file(const char *path, const char *contents)
{
    FILE *file = fopen(path, "w");
    assert(file);
    fputs(contents, file);
    fclose(file);
}

static void test_compiled_default_has_no_binds(void)
{
    kl_config_t config = kl_config_default();

    assert(config.binding_count == 0);
    assert(!config.custom_binds);
    assert(config.mod_modifier == KL_MODIFIER_ALT);
}

static void test_default_config_file_controls(void)
{
    kl_config_t config = kl_config_default();
    char error[256] = {0};
    assert(kl_config_load_file("resources/default-config.kdl", &config, error, sizeof(error)));

    assert(config.custom_binds);
    assert(config.binding_count == 14);
    assert(config.window_rule_count == 8);
    assert(config.mod_modifier == KL_MODIFIER_ALT);
    assert(strcmp(config.window_rules[0].subrole, "AXDialog") == 0);
    assert(config.window_rules[0].action == KL_WINDOW_RULE_ACTION_FLOATING);
    kl_binding_t *binding = kl_config_find_binding(
        &config,
        (kl_binding_trigger_t) {
            .kind = KL_BINDING_TRIGGER_KEY,
            .key = KL_KEY_SYMBOL_LEFT,
        },
        KL_MODIFIER_ALT);
    assert(binding);
    assert(binding->action == KL_ACTION_SCROLL_LEFT);

    binding = kl_config_find_binding(
        &config,
        (kl_binding_trigger_t) {
            .kind = KL_BINDING_TRIGGER_MOUSE_RIGHT,
            .key = KL_KEY_SYMBOL_NONE,
        },
        KL_MODIFIER_ALT);
    assert(binding);
    assert(binding->action == KL_ACTION_START_RESIZE);

    binding = kl_config_find_binding(
        &config,
        (kl_binding_trigger_t) {
            .kind = KL_BINDING_TRIGGER_KEY,
            .key = KL_KEY_SYMBOL_BRACKET_LEFT,
        },
        KL_MODIFIER_ALT);
    assert(binding);
    assert(binding->action == KL_ACTION_SET_COLUMN_WIDTH);
    assert(strcmp(binding->argument, "-10%") == 0);

    binding = kl_config_find_binding(
        &config,
        (kl_binding_trigger_t) {
            .kind = KL_BINDING_TRIGGER_KEY,
            .key = KL_KEY_SYMBOL_BRACKET_RIGHT,
        },
        KL_MODIFIER_ALT);
    assert(binding);
    assert(binding->action == KL_ACTION_SET_COLUMN_WIDTH);
    assert(strcmp(binding->argument, "+10%") == 0);

    binding = kl_config_find_binding(
        &config,
        (kl_binding_trigger_t) {
            .kind = KL_BINDING_TRIGGER_WHEEL_DOWN,
            .key = KL_KEY_SYMBOL_NONE,
        },
        KL_MODIFIER_ALT);
    assert(binding);
    assert(binding->action == KL_ACTION_SCROLL_RIGHT);
}

static void test_niri_style_binds_replace_loaded_defaults(void)
{
    const char *path = "build/test-config-binds.conf";
    write_file(
        path,
        "mod-key = super\n"
        "binds {\n"
        "    Mod+Left { focus-column-left; }\n"
        "    Mod+Ctrl+Right { move-column-right; }\n"
        "    Mod+Minus { set-column-width \"-10%\"; }\n"
        "    Mod+MouseLeft { start-interactive-move; }\n"
        "    Mod+Q repeat=false { close-window; }\n"
        "}\n");

    kl_config_t config = kl_config_default();
    char error[256] = {0};
    assert(kl_config_load_file("resources/default-config.kdl", &config, error, sizeof(error)));
    assert(config.binding_count == 14);
    assert(kl_config_load_file(path, &config, error, sizeof(error)));
    assert(config.custom_binds);
    assert(config.mod_modifier == KL_MODIFIER_SUPER);
    assert(config.binding_count == 4);
    assert(config.unsupported_bind_count == 1);
    assert(strcmp(config.unsupported_binds[0], "close-window") == 0);

    kl_binding_t *binding = kl_config_find_binding(
        &config,
        (kl_binding_trigger_t) {
            .kind = KL_BINDING_TRIGGER_KEY,
            .key = KL_KEY_SYMBOL_LEFT,
        },
        KL_MODIFIER_SUPER);
    assert(binding);
    assert(binding->action == KL_ACTION_FOCUS_COLUMN_LEFT);

    binding = kl_config_find_binding(
        &config,
        (kl_binding_trigger_t) {
            .kind = KL_BINDING_TRIGGER_KEY,
            .key = KL_KEY_SYMBOL_RIGHT,
        },
        KL_MODIFIER_SUPER | KL_MODIFIER_CTRL);
    assert(binding);
    assert(binding->action == KL_ACTION_MOVE_COLUMN_RIGHT);

    binding = kl_config_find_binding(
        &config,
        (kl_binding_trigger_t) {
            .kind = KL_BINDING_TRIGGER_KEY,
            .key = KL_KEY_SYMBOL_MINUS,
        },
        KL_MODIFIER_SUPER);
    assert(binding);
    assert(binding->action == KL_ACTION_SET_COLUMN_WIDTH);
    assert(strcmp(binding->argument, "-10%") == 0);

    binding = kl_config_find_binding(
        &config,
        (kl_binding_trigger_t) {
            .kind = KL_BINDING_TRIGGER_MOUSE_LEFT,
            .key = KL_KEY_SYMBOL_NONE,
        },
        KL_MODIFIER_SUPER);
    assert(binding);
    assert(binding->action == KL_ACTION_START_MOVE);
}

static void test_input_block_mod_key(void)
{
    const char *path = "build/test-config-input.conf";
    write_file(
        path,
        "input {\n"
        "    mod-key \"Super\"\n"
        "}\n"
        "binds {\n"
        "    Mod+F repeat=false { maximize-column; }\n"
        "}\n");

    kl_config_t config = kl_config_default();
    char error[256] = {0};
    assert(kl_config_load_file(path, &config, error, sizeof(error)));
    assert(config.mod_modifier == KL_MODIFIER_SUPER);

    kl_binding_t *binding = kl_config_find_binding(
        &config,
        (kl_binding_trigger_t) {
            .kind = KL_BINDING_TRIGGER_KEY,
            .key = KL_KEY_SYMBOL_F,
        },
        KL_MODIFIER_SUPER);
    assert(binding);
    assert(binding->action == KL_ACTION_MAXIMIZE_COLUMN);
    assert(!binding->repeat);
}

static void test_window_rules_parse_policy_actions(void)
{
    const char *path = "build/test-config-window-rules.conf";
    write_file(
        path,
        "window-rule {\n"
        "    match role=\"AXWindow\" subrole=\"AXDialog\"\n"
        "    open-floating true\n"
        "}\n"
        "window-rule {\n"
        "    match subrole=\"AXPopover\"\n"
        "    ignore true\n"
        "}\n"
        "window-rule {\n"
        "    match app-id=\"com.apple.systempreferences\" app-name=\"System Settings\"\n"
        "    open-floating true\n"
        "}\n");

    kl_config_t config = kl_config_default();
    char error[256] = {0};
    assert(kl_config_load_file(path, &config, error, sizeof(error)));

    assert(config.window_rule_count == 3);
    assert(strcmp(config.window_rules[0].role, "AXWindow") == 0);
    assert(strcmp(config.window_rules[0].subrole, "AXDialog") == 0);
    assert(config.window_rules[0].action == KL_WINDOW_RULE_ACTION_FLOATING);
    assert(strcmp(config.window_rules[1].subrole, "AXPopover") == 0);
    assert(config.window_rules[1].action == KL_WINDOW_RULE_ACTION_IGNORED);
    assert(strcmp(config.window_rules[2].app_id, "com.apple.systempreferences") == 0);
    assert(strcmp(config.window_rules[2].app_name, "System Settings") == 0);
    assert(config.window_rules[2].action == KL_WINDOW_RULE_ACTION_FLOATING);
}

static void test_window_rule_unsupported_match_does_not_match_everything(void)
{
    const char *path = "build/test-config-window-rule-unsupported.conf";
    write_file(
        path,
        "window-rule {\n"
        "    match title=\"Open\"\n"
        "    open-floating true\n"
        "}\n");

    kl_config_t config = kl_config_default();
    char error[256] = {0};
    assert(kl_config_load_file(path, &config, error, sizeof(error)));
    assert(config.window_rule_count == 0);
}

int main(void)
{
    assert(access("build", F_OK) == 0);

    test_compiled_default_has_no_binds();
    test_default_config_file_controls();
    test_niri_style_binds_replace_loaded_defaults();
    test_input_block_mod_key();
    test_window_rules_parse_policy_actions();
    test_window_rule_unsupported_match_does_not_match_everything();

    puts("config tests passed");
    return 0;
}
