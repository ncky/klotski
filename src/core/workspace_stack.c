#include "core/workspace_stack.h"

#include <string.h>

void kl_workspace_stack_init(kl_workspace_stack_t *stack, kl_layout_options_t options)
{
    memset(stack, 0, sizeof(*stack));
    stack->options = options;
    stack->count = 1;
    stack->active = 0;
    kl_workspace_init(&stack->workspaces[0], options);
}

kl_workspace_t *kl_workspace_stack_active(kl_workspace_stack_t *stack)
{
    return &stack->workspaces[stack->active];
}

const kl_workspace_t *kl_workspace_stack_active_const(const kl_workspace_stack_t *stack)
{
    return &stack->workspaces[stack->active];
}

bool kl_workspace_stack_switch(kl_workspace_stack_t *stack, int direction)
{
    if (direction == 0) {
        return true;
    }

    if (direction < 0) {
        if (stack->active == 0) {
            return false;
        }

        stack->active--;
        return true;
    }

    if (stack->active + 1 == stack->count) {
        if (stack->count == KL_WORKSPACE_STACK_MAX_WORKSPACES) {
            return false;
        }

        kl_workspace_init(&stack->workspaces[stack->count], stack->options);
        stack->count++;
    }

    stack->active++;
    return true;
}
