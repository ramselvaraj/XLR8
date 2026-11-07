# Out-of-tree module. On the board:  make -C /lib/modules/$(uname -r)/build M=$PWD modules
obj-m += xlr8.o
KDIR ?= /lib/modules/$(shell uname -r)/build
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
