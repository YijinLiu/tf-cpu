WORK_DIR:=$(shell readlink -f $(dir $(lastword $(MAKEFILE_LIST))))

VERSION?=1.11.0
BLAS?=MKL
CPU?=native
MKLDNN_VERSION?=0.16

name_extra:=$(shell echo $(BLAS) | tr A-Z a-z)
ifeq ($(BLAS),MKL)
	ifneq ($(MKLDNN_VERSION),)
		name_extra:=mkldnn
	endif
endif
ifneq ($(name_extra),)
	name_extra:=-$(name_extra)
endif

default:
	cd $(WORK_DIR)
	docker build -t ${USER}/tensorflow$(name_extra)-$(CPU):$(VERSION) \
	             --build-arg NAME=${USER} --build-arg UID=$(shell id -u) \
	             --build-arg GID=$(shell id -g) --build-arg VERSION=$(VERSION) \
	             --build-arg BLAS=$(BLAS) --build-arg MKLDNN_VERSION=$(MKLDNN_VERSION) \
	             --build-arg MOPTS="-march=$(CPU)" .
