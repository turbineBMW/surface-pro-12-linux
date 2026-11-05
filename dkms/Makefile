KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/surface modules
	$(MAKE) -C $(KDIR) M=$(CURDIR)/bluetooth modules
	$(MAKE) -C $(KDIR) M=$(CURDIR)/input modules
	$(MAKE) -C $(KDIR) M=$(CURDIR)/nfc modules
	$(MAKE) -C $(KDIR) M=$(CURDIR)/media modules
	$(MAKE) -C $(KDIR) M=$(CURDIR)/bridge modules
	$(MAKE) -C $(KDIR) M=$(CURDIR)/isys modules
	$(MAKE) -C $(KDIR) M=$(CURDIR)/power modules
ifeq ($(shell printf '%s\n' 7.4 $(firstword $(subst -, ,$(KVER))) | sort -V | head -n1),7.4)
	$(MAKE) -C $(KDIR) M=$(CURDIR)/psys IPU6_SRC=$(CURDIR)/isys modules
endif

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/psys clean
	rm -rf surface bluetooth input nfc media bridge isys power src
