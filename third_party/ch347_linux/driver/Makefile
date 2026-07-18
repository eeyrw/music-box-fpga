ifeq ($(KERNELRELEASE), )

KERNELDIR := /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

MODULE_DIR := /lib/modules/$(shell uname -r)/kernel/drivers/usb/misc
UDEV_RULE := /etc/udev/rules.d/99-ch34x_pis.rules

default:
	$(MAKE) -C $(KERNELDIR) M=$(PWD)

clean:
	rm -rf *.mk .tmp_versions Module.symvers *.mod.c *.o *.ko .*.cmd \
		Module.markers modules.order *.a *.mod

load:
	insmod ch34x_pis.ko

unload:
	rmmod ch34x_pis

install: default
	insmod ch34x_pis.ko || true

	mkdir -p $(MODULE_DIR)
	cp -f ch34x_pis.ko $(MODULE_DIR)/
	depmod -a

	@echo "Installing udev rule..."
	@printf 'KERNEL=="ch34x_pis*", GROUP="plugdev", MODE="0660"\n' > $(UDEV_RULE)
	udevadm control --reload-rules
	udevadm trigger

	@echo
	@echo "Driver installed."
	@echo
	@echo "If your user is not in the plugdev group, run:"
	@echo "    sudo usermod -aG plugdev $$USER"
	@echo
	@echo "Then log out and log back in."

uninstall:
	rmmod ch34x_pis || true
	rm -f $(MODULE_DIR)/ch34x_pis.ko
	depmod -a

	rm -f $(UDEV_RULE)
	udevadm control --reload-rules
	udevadm trigger

else

obj-m := ch34x_pis.o

endif
