WORK_DIR:=$(shell readlink -f $(dir $(lastword $(MAKEFILE_LIST))))

BLAS?=MKL

name_extra:=$(shell echo $(BLAS) | tr A-Z a-z)
ifneq ($(name_extra),)
	name_extra:=-$(name_extra)
endif

default:
	cd $(WORK_DIR)
	docker build -t ${USER}/tensorflow$(name_extra):2.2.1 \
	             --build-arg NAME=${USER} --build-arg UID=$(shell id -u) \
	             --build-arg GID=$(shell id -g) \
	             --build-arg BLAS=$(BLAS) --build-arg MOPTS="-march=native" .

# To create a container:
# docker run -it --device /dev/dri:/dev/dri -v /home/${USER}:/home/${USER} --user=${USER} \
#     --workdir=/home/${USER} --name "tf-cpu-${USER}" ${USER}/tensorflow-mkl:2.2.1
