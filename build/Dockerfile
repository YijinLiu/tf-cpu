FROM ubuntu:18.04

ENV DEBIAN_FRONTEND noninteractive
RUN apt update && apt upgrade -y && \
    apt install -qq -y --no-install-recommends \
        apt-transport-https apt-utils autoconf automake bash bash-completion build-essential \
        ca-certificates clinfo cpio curl dpkg git gpg-agent libgfortran-5-dev libjpeg-dev libtool \
        libusb-1.0-0-dev openjdk-8-jdk pkg-config python3 python3-dev python3-pip \
        software-properties-common ssh sudo tzdata unzip wget yasm zlib1g-dev && \
    add-apt-repository -y ppa:intel-opencl/intel-opencl && \
    echo "deb https://packages.cloud.google.com/apt coral-edgetpu-stable main" > \
        /etc/apt/sources.list.d/coral-edgetpu.list && \
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add - && \
    apt update && \
    apt install -y --no-install-recommends intel-opencl-icd libedgetpu1-std edgetpu-compiler && \
    pip3 install --upgrade pip setuptools && apt autoremove -y python3-pip && \
    pip install --upgrade numpy && \
    ln -s python3 /usr/bin/python && \
    echo America/Los_Angeles > /etc/timezone && \
    dpkg-reconfigure --frontend noninteractive tzdata

ARG NAME
ADD build.sh tensorflow.patch /home/$NAME/build/
ARG UID
ARG GID
RUN groupadd -g $GID $NAME && \
    useradd -u $UID -g $NAME --groups sudo --shell /bin/bash $NAME && \
    echo "$NAME ALL = NOPASSWD: ALL" > /etc/sudoers.d/$NAME && \
    chown -R $NAME:$NAME /home/$NAME && \
    usermod -G video $NAME
USER $NAME
WORKDIR /home/$NAME

ARG BLAS
ARG MOPTS
RUN cd build && \
    ./build.sh --blas=$BLAS --mopts="$MOPTS" && \
    cd .. && \
    rm -rf build
