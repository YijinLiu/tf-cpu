FROM ubuntu:16.04

RUN apt update && apt upgrade -y && \
    apt install -y --no-install-recommends bash bash-completion ca-certificates dpkg pkg-config \
        ssh sudo tzdata && \
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
