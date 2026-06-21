CC := xcrun clang

CPPFLAGS := -Isrc
CFLAGS := -std=c11 -Wall -Wextra -Wpedantic -g -O2
OBJCFLAGS := -fobjc-arc
FRAMEWORKS := -framework Cocoa -framework ApplicationServices

BUILD_DIR := build
BIN_DIR := bin

LAYOUT_TEST := $(BUILD_DIR)/test_layout
CONFIG_TEST := $(BUILD_DIR)/test_config
GESTURE_TEST := $(BUILD_DIR)/test_gesture
INPUT_TEST := $(BUILD_DIR)/test_input
INTERACTION_TEST := $(BUILD_DIR)/test_interaction
BENCH_CORE := $(BUILD_DIR)/bench_core
KLOTSKI := $(BIN_DIR)/klotski
KLOTSKI_HARNESS := $(BIN_DIR)/klotski-harness
KLOTSKI_SEND_INPUT := $(BIN_DIR)/klotski-send-input
KLOTSKI_LIST_WINDOWS := $(BIN_DIR)/klotski-list-windows

CORE_SRC := \
	src/core/config.c \
	src/core/controller.c \
	src/core/gesture.c \
	src/core/input.c \
	src/core/interaction.c \
	src/core/workspace.c \
	src/core/workspace_stack.c \
	src/layout/strip.c

MACOS_SRC := \
	src/main.m \
	src/platform/macos/accessibility.m \
	src/platform/macos/runtime.m \
	src/platform/macos/window_observer.m \
	src/platform/macos/window_server.m

.PHONY: all test bench bench-core bench-macos bench-window-add bench-window-burst bench-window-lifecycle bench-window-policy bench-window-fullscreen bench-window-gap service-install service-uninstall service-start service-stop service-restart service-status service-logs service-doctor service-disable service-enable clean

all: test $(KLOTSKI)

test: $(LAYOUT_TEST) $(CONFIG_TEST) $(GESTURE_TEST) $(INPUT_TEST) $(INTERACTION_TEST)
	$(LAYOUT_TEST)
	$(CONFIG_TEST)
	$(GESTURE_TEST)
	$(INPUT_TEST)
	$(INTERACTION_TEST)

bench: bench-core

bench-core: $(BENCH_CORE)
	$(BENCH_CORE)

bench-macos:
	scripts/benchmark.sh

bench-window-add:
	scripts/benchmark-window-add.sh

bench-window-burst:
	scripts/benchmark-window-burst.sh

bench-window-lifecycle:
	scripts/benchmark-window-lifecycle.sh

bench-window-policy:
	scripts/benchmark-window-policy.sh

bench-window-fullscreen:
	scripts/benchmark-window-fullscreen.sh

bench-window-gap:
	scripts/benchmark-window-gap.sh

service-install: $(KLOTSKI)
	scripts/klotski-service.sh install

service-uninstall:
	scripts/klotski-service.sh uninstall

service-start: $(KLOTSKI)
	scripts/klotski-service.sh start

service-stop:
	scripts/klotski-service.sh stop

service-restart: $(KLOTSKI)
	scripts/klotski-service.sh restart

service-status:
	scripts/klotski-service.sh status

service-logs:
	scripts/klotski-service.sh logs

service-doctor: $(KLOTSKI)
	scripts/klotski-service.sh doctor

service-disable:
	scripts/klotski-service.sh disable

service-enable: $(KLOTSKI)
	scripts/klotski-service.sh enable

$(LAYOUT_TEST): tests/test_layout.c $(CORE_SRC) src/core/config.h src/core/controller.h src/core/gesture.h src/core/workspace.h src/core/workspace_stack.h src/layout/strip.h src/layout/geometry.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) tests/test_layout.c $(CORE_SRC) -o $@

$(CONFIG_TEST): tests/test_config.c $(CORE_SRC) src/core/config.h src/layout/strip.h src/layout/geometry.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) tests/test_config.c $(CORE_SRC) -o $@

$(GESTURE_TEST): tests/test_gesture.c $(CORE_SRC) src/core/gesture.h src/core/controller.h src/core/workspace.h src/core/workspace_stack.h src/layout/strip.h src/layout/geometry.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) tests/test_gesture.c $(CORE_SRC) -o $@

$(INPUT_TEST): tests/test_input.c $(CORE_SRC) src/core/input.h src/core/controller.h src/core/workspace.h src/core/workspace_stack.h src/layout/strip.h src/layout/geometry.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) tests/test_input.c $(CORE_SRC) -o $@

$(INTERACTION_TEST): tests/test_interaction.c $(CORE_SRC) src/core/interaction.h src/core/input.h src/core/controller.h src/core/workspace.h src/core/workspace_stack.h src/layout/strip.h src/layout/geometry.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) tests/test_interaction.c $(CORE_SRC) -o $@

$(BENCH_CORE): tools/bench/core.c $(CORE_SRC) src/core/config.h src/core/controller.h src/core/gesture.h src/core/workspace.h src/core/workspace_stack.h src/layout/strip.h src/layout/geometry.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) tools/bench/core.c $(CORE_SRC) -o $@

$(KLOTSKI): $(CORE_SRC) $(MACOS_SRC) src/core/controller.h src/core/gesture.h src/core/workspace.h src/core/workspace_stack.h src/layout/strip.h src/layout/geometry.h src/platform/macos/accessibility.h src/platform/macos/runtime.h src/platform/macos/window_observer.h src/platform/macos/window_server.h
	mkdir -p $(BIN_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(OBJCFLAGS) $(CORE_SRC) $(MACOS_SRC) $(FRAMEWORKS) -o $@

$(KLOTSKI_HARNESS): tools/harness/windows.m
	mkdir -p $(BIN_DIR)
	$(CC) $(CFLAGS) $(OBJCFLAGS) tools/harness/windows.m -framework Cocoa -o $@

$(KLOTSKI_SEND_INPUT): tools/harness/send_input.m
	mkdir -p $(BIN_DIR)
	$(CC) $(CFLAGS) $(OBJCFLAGS) tools/harness/send_input.m -framework ApplicationServices -o $@

$(KLOTSKI_LIST_WINDOWS): tools/harness/list_windows.m
	mkdir -p $(BIN_DIR)
	$(CC) $(CFLAGS) $(OBJCFLAGS) tools/harness/list_windows.m -framework ApplicationServices -o $@

clean:
	rm -rf $(BUILD_DIR) $(BIN_DIR)
