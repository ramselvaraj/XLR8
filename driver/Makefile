# Out-of-tree modules. On the board:  make -C /usr/src/kernel M=$PWD modules
#   v4l2-mem2mem.ko   the mem2mem framework (the board kernel does not build it), upstream 5.15.19
#   xlr8.ko           the core driver: /dev/xlr8
#   xlr8_v4l2.ko      the V4L2 blur device, needs the two above
obj-m += xlr8.o xlr8_v4l2.o third_party/v4l2-mem2mem.o
KDIR ?= /lib/modules/$(shell uname -r)/build
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
