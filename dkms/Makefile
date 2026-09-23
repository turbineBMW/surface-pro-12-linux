KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/surface modules
	$(MAKE) -C $(KDIR) M=$(CURDIR)/bluetooth modules
	$(MAKE) -C $(KDIR) M=$(CURDIR)/input modules
	$(MAKE) -C $(KDIR) M=$(CURDIR)/nfc modules

clean:
	rm -rf surface bluetooth input nfc src
