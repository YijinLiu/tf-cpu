WORK_DIR:=$(shell readlink -f $(dir $(lastword $(MAKEFILE_LIST))))

VERSION?=1.8.0
BLAS?=MKL
MOPTS?=-march=native

default:
	cd $(WORK_DIR)
	docker build -t ${USER}/tensorflow-$(shell echo $(BLAS) | tr A-Z a-z):$(VERSION) \
	             --build-arg NAME=${USER} --build-arg UID=$(shell id -u) --build-arg GID=$(shell id -g) \
	             --build-arg VERSION=$(VERSION) --build-arg BLAS=$(BLAS) --build-arg MOPTS=$(MOPTS) .
