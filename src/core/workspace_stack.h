#ifndef KLOTSKI_CORE_WORKSPACE_STACK_H
#define KLOTSKI_CORE_WORKSPACE_STACK_H

#include <stdbool.h>
#include <stddef.h>

#include "core/workspace.h"

#define KL_WORKSPACE_STACK_MAX_WORKSPACES 16

typedef struct kl_workspace_stack {
    kl_workspace_t workspaces[KL_WORKSPACE_STACK_MAX_WORKSPACES];
    kl_layout_options_t options;
    size_t count;
    size_t active;
} kl_workspace_stack_t;

void kl_workspace_stack_init(kl_workspace_stack_t *stack, kl_layout_options_t options);
kl_workspace_t *kl_workspace_stack_active(kl_workspace_stack_t *stack);
const kl_workspace_t *kl_workspace_stack_active_const(const kl_workspace_stack_t *stack);
bool kl_workspace_stack_switch(kl_workspace_stack_t *stack, int direction);

#endif
