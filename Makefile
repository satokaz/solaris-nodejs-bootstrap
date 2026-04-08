.PHONY: bootstrap refresh-version refresh-patches download extract patch build install verify clean distclean

SCRIPT = ./scripts/bootstrap-node.sh

bootstrap:
	$(SCRIPT) bootstrap

refresh-version:
	$(SCRIPT) refresh-version

refresh-patches:
	$(SCRIPT) refresh-patches

download:
	$(SCRIPT) download

extract:
	$(SCRIPT) extract

patch:
	$(SCRIPT) patch

build:
	$(SCRIPT) build

install:
	$(SCRIPT) install

verify:
	$(SCRIPT) verify

clean:
	$(SCRIPT) clean

distclean:
	$(SCRIPT) distclean
