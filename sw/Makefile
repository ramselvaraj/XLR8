# libxlr8, the renderer app and the host tests.
#   make            build for the machine you are on (run this on the board)
#   make test       host-side unit tests (ASan + UBSan), no hardware needed
CC      ?= gcc
CFLAGS  ?= -O2 -g -Wall -Wextra
INC     := -Ilib -I../driver -Iapps
BUILD   := build

all: $(BUILD)/ball $(BUILD)/libxlr8.a

$(BUILD)/libxlr8.a: lib/xlr8.c lib/xlr8.h ../driver/xlr8_uapi.h
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(INC) -c lib/xlr8.c -o $(BUILD)/xlr8.o
	ar rcs $@ $(BUILD)/xlr8.o

$(BUILD)/ball: apps/ball.c apps/imgout.h $(BUILD)/libxlr8.a
	$(CC) $(CFLAGS) $(INC) apps/ball.c $(BUILD)/libxlr8.a -o $@

# host tests: library error paths against a fake driver, and the image writers
$(BUILD)/test_lib: tests/test_lib.c lib/xlr8.c lib/xlr8.h ../driver/xlr8_uapi.h
	mkdir -p $(BUILD)
	$(CC) -O1 -g -Wall -Wextra -fsanitize=address,undefined -fno-omit-frame-pointer $(INC) tests/test_lib.c lib/xlr8.c -o $@

$(BUILD)/test_img: tests/test_img.c apps/imgout.h
	mkdir -p $(BUILD)
	$(CC) -O1 -g -Wall -Wextra -fsanitize=address,undefined $(INC) tests/test_img.c -o $@

test: $(BUILD)/test_lib $(BUILD)/test_img
	$(BUILD)/test_lib
	$(BUILD)/test_img $(BUILD)/img_out

clean:
	rm -rf $(BUILD)
