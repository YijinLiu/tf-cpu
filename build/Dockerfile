FROM ubuntu:18.04

ENV DEBIAN_FRONTEND noninteractive
RUN apt update && apt upgrade -y && \
    apt install -qq -y --no-install-recommends \
        autoconf automake bash bash-completion build-essential ca-certificates cmake cpio curl \
        dpkg git libgfortran-5-dev libjpeg-dev libtool openjdk-8-jdk pkg-config \
        python python-future python3 python3-pip ssh sudo tzdata unzip wget yasm zlib1g-dev && \
    echo America/Los_Angeles > /etc/timezone && \
    dpkg-reconfigure --frontend noninteractive tzdata

ARG NAME
ADD build.sh /home/$NAME/build/
ARG UID
ARG GID
RUN groupadd -g $GID $NAME && \
    useradd -u $UID -g $NAME --groups sudo --shell /bin/bash $NAME && \
    echo "$NAME ALL = NOPASSWD: ALL" > /etc/sudoers.d/$NAME && \
    chown -R $NAME:$NAME /home/$NAME
USER $NAME
WORKDIR /home/$NAME

ARG VERSION
ARG BLAS
ARG MKLDNN_VERSION
ARG MOPTS
RUN cd build && \
    ./build.sh --version=$VERSION --blas=$BLAS --mkldnn_version=$MKLDNN_VERSION --mopts="$MOPTS" && \
    cd .. && \
    rm -rf build
