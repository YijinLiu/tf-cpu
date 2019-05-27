WORK_DIR:=$(shell readlink -f $(dir $(lastword $(MAKEFILE_LIST))))

VERSION?=1.14.0-rc0
BLAS?=MKL
MKLDNN_VERSION?=0.19

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
	docker build -t ${USER}/tensorflow$(name_extra):$(VERSION) \
	             --build-arg NAME=${USER} --build-arg UID=$(shell id -u) \
	             --build-arg GID=$(shell id -g) --build-arg VERSION=$(VERSION) \
	             --build-arg BLAS=$(BLAS) --build-arg MKLDNN_VERSION=$(MKLDNN_VERSION) \
	             --build-arg MOPTS="-msse2" .
