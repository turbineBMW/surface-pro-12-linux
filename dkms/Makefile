KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/surface modules
	$(MAKE) -C $(KDIR) M=$(CURDIR)/bluetooth modules

clean:
	rm -rf surface bluetooth src
