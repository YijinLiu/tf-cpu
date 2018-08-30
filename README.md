# tf-cpu

## How to run on Ubuntu 16.04


```
# clone repo
git clone http://github.com/jefby/tf-cpu

# install docker build tools
sudo apt install -y docker docker-io

# docker build from scratch
cd tf-cpu/build
sudo docker build --build-arg NAME=jefby --build-arg GID=5000 --build-arg UID=5000 --build-arg VERSION=1.10 --build-arg MKLDNN_VERSION=0.14 --build-arg BLAS=MKL --build-arg MOPTS=-march=native .

```

