#!/bin/bash

RED='\e[0;31m'
GREEN='\e[0;92m'
YELLOW='\e[0;33m'
NC='\e[0m'

ARCH=$(uname -m)
BASEDIR=$(dirname $(readlink -f $0))

usage() {
    echo "Options:
    --blas=              MKL/OpenBLAS/ATLAS
    --version=           Tensorflow version.
"
}

blas=MKL
prefix=/usr/local
# Use "gcc -march=native -Q --help=target" to see which options are enabled.
mopts="-march=native"
parallel=$(expr `nproc` / 2)

OPTS=`getopt -n 'build.sh' -o b:,m:,p: -l blas:,prefix:,mopts:,parallel: -- "$@"`
rc=$?
if [ $rc != 0 ] ; then
    usage
    exit 1
fi
eval set -- "$OPTS"
while true; do
    case "$1" in
        -b | --blas )               blas="$2" ; shift 2 ;;
        -p | --prefix )             prefix="$2" ; shift 2 ;;
        -m | --mopts )              mopts="$2" ; shift 2 ;;
        --parallel )                parallel="$2" ; shift 2 ;;
        -- ) shift; break ;;
        * ) echo -e "${RED}Invalid option: -$1${NC}" >&2 ; usage ; exit 1 ;;
    esac
done
echo -e ${GREEN}BLAS: $blas${NC}

MAKE="make -j ${parallel}"

install_cmake() {
    ver=3.15.0
    if [ ! -d "cmake-$ver" ] ; then
        if [ ! -f "cmake-$ver.tar.gz" ] ; then
            wget https://github.com/Kitware/CMake/releases/download/v$ver/cmake-$ver.tar.gz
            rc=$?
            if [ $rc != 0 ]; then
                echo -e "${RED}Failed to download cmake source code${NC}"
                return 1
            fi
        fi
        tar xvf cmake-$ver.tar.gz
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to extract cmake source code${NC}"
            return 1
        fi
    fi
    cd cmake-$ver
    ./bootstrap --prefix=$prefix -- -DCMAKE_BUILD_TYPE:STRING=Release &&
    $MAKE && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build cmake${NC}"
        return 1
    fi
    cd ..
}

install_gperftools() {
    # tcmalloc doesn't work on arm. No idea why.
    if [ "$ARCH" == "armv7l" ]; then
        return
    fi

    if [ ! -d "gperftools" ]; then
        git clone --depth=1 https://github.com/gperftools/gperftools -b gperftools-2.7
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download gperftools${NC}"
            return 1
        fi
    fi
    cd gperftools
    ./autogen.sh &&
    ./configure --with-pic --enable-shared --enable-static --with-tcmalloc-pagesize=32 \
        --prefix=$prefix &&
    $MAKE && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build gperftools${NC}"
        return 1
    fi

    cd ..
}

install_headers() {
    src=$1
    dst=$2
    for header in $(find $src -name "*.h" -o -name "*.inc") ; do
        dir=$(dirname $header)
        sudo mkdir -p $dst/$dir && sudo cp $header $dst/$dir/
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to install $header!${NC}"
            return 1
        fi
    done
}

install_atlas() {
    wget https://managedway.dl.sourceforge.net/project/math-atlas/Stable/3.10.3/atlas3.10.3.tar.bz2
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to download ATLAS source!${NC}"
        return 1
    fi
    tar xvjf atlas3.10.3.tar.bz2
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to extract ATLAS source!${NC}"
        return 1
    fi
    wget http://www.netlib.org/lapack/lapack-3.7.1.tgz
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to download LAPACK source!${NC}"
        return 1
    fi
    cd ATLAS
    mkdir build
    cd build
    ../configure --prefix=$prefix/ATLAS --cripple-atlas-performance --dylibs -t 0 \
        --with-netlib-lapack-tarfile=../../lapack-3.7.1.tgz
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to configure ATLAS!${NC}"
        return 1
    fi
    $MAKE && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build ATLAS!${NC}"
        return 1
    fi
    cd ../..
}

install_openblas() {
    git clone --depth=1 https://github.com/xianyi/OpenBLAS -b v0.3.10
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to download OpenBLAS source!${NC}"
        return 1
    fi
    cd OpenBLAS
    $MAKE USE_THREAD=0 USE_OPENMP=0 &&
    sudo make PREFIX=$prefix/OpenBLAS install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to compile OpenBLAS!${NC}"
        return 1
    fi
    cd ..
}

# Visit https://software.seek.intel.com/performance-libraries
# to find latest versions of MKL and IPP.
install_mkl() {
    prid="16903"
    ver="2020.3.279"
    if [ ! -d "l_mkl_${ver}" ]; then
        if [ ! -f "l_mkl_${ver}.tgz" ]; then
            wget http://registrationcenter-download.intel.com/akdlm/irc_nas/tec/${prid}/l_mkl_${ver}.tgz
            rc=$?
            if [ $rc != 0 ]; then
                echo -e "${RED}Failed to download Intel MKL!${NC}"
                return 1
            fi
        fi
        tar xvzf l_mkl_${ver}.tgz && chmod +x l_mkl_${ver}/install.sh
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to extract Intel MKL!${NC}"
            return 1
        fi
    fi
    echo 'ACCEPT_EULA=accept
CONTINUE_WITH_OPTIONAL_ERROR=yes
CONTINUE_WITH_INSTALLDIR_OVERWRITE=yes
PSET_INSTALL_DIR=/opt/intel
ARCH_SELECTED=INTEL64
PSET_MODE=install
COMPONENTS=DEFAULTS' > l_mkl_${ver}.silent.cfg &&
    sudo l_mkl_${ver}/install.sh -s l_mkl_${ver}.silent.cfg &&
    sudo mkdir -p $prefix/intel/mkl/lib &&
    sudo cp -a /opt/intel/mkl/include/ $prefix/intel/mkl &&
    sudo install /opt/intel/mkl/lib/intel64/libmkl_intel_lp64.a \
            /opt/intel/mkl/lib/intel64/libmkl_sequential.a \
            /opt/intel/mkl/lib/intel64/libmkl_core.a \
            /opt/intel/mkl/lib/intel64/libmkl_blas95_lp64.a \
            /opt/intel/mkl/lib/intel64/libmkl_lapack95_lp64.a \
            /opt/intel/mkl/lib/intel64/libmkl_gf_lp64.a \
            $prefix/intel/mkl/lib &&
    sudo install l_mkl_${ver}/license.txt $prefix/intel/mkl &&
    sudo rm -rf /opt/intel
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install Intel MKL!${NC}"
        return 1
    fi
}

install_blas() {
    case "$blas" in
        "ATLAS" ) install_atlas ;;
        "OpenBLAS" ) install_openblas ;;
        "MKL" ) install_mkl ;;
        * ) echo -e "${YELLOW}No BLAS will be install.${NC}"
    esac
}

install_protobuf() {
    if [ ! -d "protobuf" ]; then
        git clone --depth=1 https://github.com/google/protobuf -b v3.8.0
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download protobuf.${NC}"
            return 1
        fi
    fi

    cd protobuf
    opts=
    if [ "$ARCH" == "armv7l" ]; then
        opts="--with-pic"
    fi
    ./autogen.sh &&
    ./configure --enable-static --disable-shared $opts --prefix=$prefix &&
    $MAKE && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build protobuf${NC}"
        return 1
    fi
    cd ..
}

install_abseil_cpp() {
    if [ ! -d "abseil-cpp" ]; then
        git clone https://github.com/abseil/abseil-cpp -b 20200923.1
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download abseil-cpp.${NC}"
            return 1
        fi
    fi
    cd abseil-cpp
    mkdir -p build
    cd build
    cmake .. && make &&
    ar -r libabsl.a absl/*/CMakeFiles/*.dir/*.cc.o absl/*/CMakeFiles/*.dir/*/*.cc.o \
        absl/*/CMakeFiles/*.dir/*/*/*.cc.o absl/*/CMakeFiles/*.dir/*/*/*/*.cc.o
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build abseil-cpp!${NC}"
        return 1
    fi
    cd ..
    install_headers absl $prefix/include &&
    sudo cp build/libabsl.a $prefix/lib
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install abseil-cpp!${NC}"
        return 1
    fi
    cd ..
}

install_tensorflow() {
    bazel_version=2.0.0
    if [ ! -f bazel_${bazel_version}-linux-x86_64.deb ] ; then
        wget -O bazel_${bazel_version}-linux-x86_64.deb https://github.com/bazelbuild/bazel/releases/download/${bazel_version}/bazel_${bazel_version}-linux-x86_64.deb
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download Bazel!${NC}"
            return 1
        fi
    fi
    sudo apt install -qq -y --no-install-recommends ./bazel_${bazel_version}-linux-x86_64.deb
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install Bazel!${NC}"
        return 1
    fi

    version=2.2.1
    if [ ! -d tensorflow ] ; then
        if [[ $version =~ ^[0-9a-f]+$ ]] ; then
            git clone https://github.com/tensorflow/tensorflow &&
            cd tensorflow
            git reset $version --hard
        else
            git clone --depth=1 https://github.com/tensorflow/tensorflow -b v${version}
            cd tensorflow
        fi
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download TensorFlow source!${NC}"
            return 1
        fi
        sed "s/{{mopts}}/${mopts}/g" ${BASEDIR}/tensorflow.patch | patch -l -p1
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to patch tensorflow!${NC}"
            return 1
        fi
    else
        cd tensorflow
    fi

    # Build tensorflow lite.
    ./tensorflow/lite/tools/make/download_dependencies.sh &&
    ./tensorflow/lite/tools/make/build_lib.sh
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build Tensorflow lite!${NC}"
        return 1
    fi
    sudo mkdir -p $prefix/lib &&
    sudo install tensorflow/lite/tools/make/gen/linux_$(arch)/lib/libtensorflow-lite.a $prefix/lib &&
    sudo mkdir -p $prefix/include &&
    install_headers tensorflow/lite $prefix/include
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install Tensorflow lite!${NC}"
        return 1
    fi
    cd tensorflow/lite/tools/make/downloads/flatbuffers
    mkdir -p build
    cd build
    cmake -DCMAKE_INSTALL_PREFIX=$prefix .. && $MAKE && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install flatbuffers${NC}"
        return 1
    fi
    cd ../../../../../../../

    # Build tensorflow core.
    echo "/usr/bin/python3
/usr/lib/python3/dist-packages
n
n
n
n
${mopts}
n" | ./configure
    TF_MKL_ROOT=$prefix/intel/mkl bazel build --config=opt --config=monolithic --config=mkl \
        --config=noaws --config=nogcp --config=nohdfs --config=nonccl \
        --jobs=${parallel} --incompatible_remove_legacy_whole_archive //tensorflow:tensorflow_cc \
        //tensorflow/tools/benchmark:benchmark_model \
        //tensorflow/tools/graph_transforms:summarize_graph
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build tensorflow!${NC}"
        return 1
    fi
    sudo mkdir -p $prefix/lib &&
    sudo install bazel-bin/tensorflow/libtensorflow_cc.so.$version $prefix/lib &&
    sudo ln -sf libtensorflow_cc.so.2.2.0 $prefix/lib/libtensorflow_cc.so.2 &&
    sudo ln -sf libtensorflow_cc.so.2 $prefix/lib/libtensorflow_cc.so &&
    sudo mkdir -p $prefix/include &&
    install_headers tensorflow/cc $prefix/include &&
    install_headers tensorflow/core/framework $prefix/include &&
    install_headers tensorflow/core/graph $prefix/include &&
    install_headers tensorflow/core/lib $prefix/include &&
    install_headers tensorflow/core/platform $prefix/include &&
    install_headers tensorflow/core/public $prefix/include &&
    install_headers tensorflow/core/util $prefix/include &&
    cd bazel-out/k8-opt/bin &&
    install_headers tensorflow/core/framework $prefix/include &&
    install_headers tensorflow/core/lib $prefix/include &&
    install_headers tensorflow/core/protobuf $prefix/include &&
    install_headers tensorflow/cc $prefix/include &&
    cd ../../.. &&
    sudo mkdir -p $prefix/include/third_party &&
    sudo cp -a third_party/eigen3 $prefix/include/third_party &&
    sudo mkdir -p $prefix/bin &&
    sudo install bazel-bin/tensorflow/tools/benchmark/benchmark_model \
                 bazel-bin/tensorflow/tools/graph_transforms/summarize_graph $prefix/bin
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install Tensorflow core!${NC}"
        return 1
    fi
    cd bazel-tensorflow/external/eigen_archive
    mkdir -p build
    cd build
    cmake -DCMAKE_INSTALL_PREFIX=$prefix -DBLAS_DIR=$prefix/intel/mkl .. && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install Eigen!${NC}"
        return 1
    fi
    cd ../../../../..
}

install_x264() {
    if [ ! -d "x264" ] ; then
        git clone http://git.videolan.org/git/x264.git -b stable
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download x264${NC}"
            return 1
        fi
    fi
    cd x264
    ./configure --enable-static --disable-cli --disable-asm --prefix=$prefix &&
    $MAKE && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install x264!${NC}"
        return 1
    fi
    cd ..
}

install_ffmpeg() {
    # Set this variable to empty to use the HEAD.
    ffver=4.0.2
    if [ ! -d "ffmpeg" ] ; then
        git clone --depth=1 git://source.ffmpeg.org/ffmpeg.git -b n$ffver
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download ffmpeg${NC}"
            return 1
        fi
    fi
    cd ffmpeg
    ./configure --enable-gpl --enable-version3 --enable-pic --enable-static --disable-shared \
                --disable-everything --enable-runtime-cpudetect --enable-libx264 \
                --enable-parser=h264 --enable-parser=mjpeg \
                --enable-parser=mpeg4video --enable-parser=mpegaudio --enable-parser=mpegvideo \
                --enable-parser=opus --enable-parser=png --enable-parser=vp8 --enable-parser=vp9 \
                --enable-protocol=file \
                --enable-muxer=image2 --enable-muxer=matroska --enable-muxer=mp4 \
                --enable-demuxer=asf --enable-demuxer=avi --enable-demuxer=flv \
                --enable-demuxer=h264 --enable-demuxer=image2 --enable-demuxer=matroska \
                --enable-demuxer=mjpeg --enable-demuxer=mov --enable-demuxer=mpjpeg \
                --enable-demuxer=ogg \
                --enable-encoder=png --enable-encoder=libx264 \
                --enable-decoder=h264 --enable-decoder=hevc --enable-decoder=mjpeg \
                --enable-decoder=mpeg4 --enable-decoder=png --enable-decoder=vp8 \
                --enable-decoder=vp9 --enable-decoder=webp \
                --enable-filter=drawtext --enable-filter=format --enable-filter=pad \
                --enable-filter=scale --prefix=$prefix &&
    $MAKE && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install ffmpeg!${NC}"
        return 1
    fi
    cd ..
}

install_gflags() {
    if [ ! -d gflags ] ; then
        git clone --depth=1 https://github.com/gflags/gflags -b v2.2.1
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download gflags source!${NC}"
            return 1
        fi
    fi
    cd gflags
    mkdir build
    cd build
    cmake -DGFLAGS_NAMESPACE=google -DCMAKE_INSTALL_PREFIX=$prefix -DBUILD_SHARED_LIBS=OFF .. && \
    $MAKE && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build gflags!${NC}"
        return 1
    fi
    cd ../..
}

install_glog() {
    if [ ! -d glog ] ; then
        git clone --depth=1 https://github.com/google/glog -b v0.3.5
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download glog source!${NC}"
            return 1
        fi
    fi
    cd glog
    aclocal && automake --add-missing && ./configure --disable-shared --with-pic=no &&
    $MAKE && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build glog!${NC}"
        return 1
    fi
    cd ..
}

install_google_benchmark() {
    if [ ! -d benchmark ] ; then
        git clone --depth=1 https://github.com/google/benchmark -b v1.4.0
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download Google benchmark source!${NC}"
            return 1
        fi
    fi
    cd benchmark
    mkdir -p build
    cd build
    cmake -DCMAKE_INSTALL_PREFIX=$prefix -DCMAKE_BUILD_TYPE=Release \
        -DBENCHMARK_ENABLE_TESTING=OFF .. &&
    $MAKE && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build Google benchmark!${NC}"
        return 1
    fi
    cd ../..
}

install_opencv() {
    ver=3.4.3
    if [ ! -d "opencv" ]; then
        git clone --depth=1 https://github.com/opencv/opencv -b ${ver}
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download opencv${NC}"
            return 1
        fi
    fi
    cd opencv
    if [ ! -d "contrib" ]; then
        git clone --depth=1 https://github.com/opencv/opencv_contrib contrib -b ${ver}
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download opencv_contrib${NC}"
            return 1
        fi
    fi
    if [ "$OS" == "Darwin" ]; then
        export CMAKE_LIBRARY_PATH=${prefix}/lib
    fi

    mkdir -p build
    cd build
    cmake -DBUILD_WITH_DEBUG_INFO=ON \
          -DBUILD_DOCS=OFF \
          -DBUILD_IPP_IW=ON \
          -DBUILD_ITT=OFF \
          -DBUILD_FAT_JAVA_LIB=OFF \
          -DBUILD_JASPER=OFF \
          -DBUILD_JPEG=OFF \
          -DBUILD_OPENEXR=OFF \
          -DBUILD_PNG=OFF \
          -DBUILD_PROTOBUF=OFF \
          -DBUILD_SHARED_LIBS=OFF \
          -DBUILD_TBB=OFF \
          -DBUILD_TIFF=OFF \
          -DBUILD_ZLIB=OFF \
          -DCMAKE_BUILD_TYPE=RelWithDebInfo \
          -DBUILD_opencv_apps=OFF \
          -DBUILD_opencv_aruco=OFF \
          -DBUILD_opencv_bioinspired=OFF \
          -DBUILD_opencv_bgsegm=OFF \
          -DBUILD_opencv_calib3d=OFF \
          -DBUILD_opencv_ccalib=OFF \
          -DBUILD_opencv_core=ON \
          -DBUILD_opencv_datasets=OFF \
          -DBUILD_opencv_dnn=OFF \
          -DBUILD_opencv_dnn_modern=OFF \
          -DBUILD_opencv_dnn_objdetect=OFF \
          -DBUILD_opencv_dpm=OFF \
          -DBUILD_opencv_face=OFF \
          -DBUILD_opencv_features2d=OFF \
          -DBUILD_opencv_flann=OFF \
          -DBUILD_opencv_fuzzy=OFF \
          -DBUILD_opencv_hfs=OFF \
          -DBUILD_opencv_highgui=OFF \
          -DBUILD_opencv_img_hash=OFF \
          -DBUILD_opencv_imgcodecs=ON \
          -DBUILD_opencv_imgproc=ON \
          -DBUILD_opencv_java=OFF \
          -DBUILD_opencv_java_bindings_generator=OFF \
          -DBUILD_opencv_line_descriptor=OFF \
          -DBUILD_opencv_ml=OFF \
          -DBUILD_opencv_objdetect=OFF \
          -DBUILD_opencv_optflow=OFF \
          -DBUILD_opencv_phase_unwrapping=OFF \
          -DBUILD_opencv_photo=OFF \
          -DBUILD_opencv_plot=OFF \
          -DBUILD_opencv_python_bindings_generator=OFF \
          -DBUILD_opencv_reg=OFF \
          -DBUILD_opencv_rgbd=OFF \
          -DBUILD_opencv_saliency=OFF \
          -DBUILD_opencv_sfm=OFF \
          -DBUILD_opencv_shape=OFF \
          -DBUILD_opencv_stereo=OFF \
          -DBUILD_opencv_stitching=OFF \
          -DBUILD_opencv_structured_light=OFF \
          -DBUILD_opencv_superres=OFF \
          -DBUILD_opencv_surface_matching=OFF \
          -DBUILD_opencv_text=OFF \
          -DBUILD_opencv_tracking=OFF \
          -DBUILD_opencv_ts=OFF \
          -DBUILD_opencv_video=OFF \
          -DBUILD_opencv_videoio=OFF \
          -DBUILD_opencv_videostab=OFF \
          -DBUILD_opencv_xfeatures2d=OFF \
          -DBUILD_opencv_ximgproc=OFF \
          -DBUILD_opencv_xobjdetect=OFF \
          -DBUILD_opencv_xphoto=OFF \
          -DCMAKE_INSTALL_PREFIX=$prefix \
          -DCMAKE_C_COMPILER=/usr/bin/gcc \
          -DCMAKE_CXX_COMPILER=/usr/bin/g++ \
          -DOPENCV_EXTRA_MODULES_PATH=../contrib/modules \
          -DUPDATE_PROTO_FILES=ON \
          -DWITH_DSHOW=OFF \
          -DWITH_DIRECTX=OFF \
          -DWITH_EIGEN=ON \
          -DWITH_FFMPEG=OFF \
          -DWITH_GPHOTO2=OFF \
          -DWITH_GSTREAMER=OFF \
          -DWITH_GTK=OFF \
          -DWITH_IPP=ON \
          -DWITH_ITT=OFF \
          -DWITH_JASPER=OFF \
          -DWITH_JPEG=ON \
          -DWITH_LIBV4L=OFF \
          -DWITH_MATLAB=OFF \
          -DWITH_OPENEXR=OFF \
          -DWITH_OPENCL=OFF \
          -DWITH_OPENCLAMDFFT=OFF \
          -DWITH_OPENCLAMDBLAS=OFF \
          -DWITH_OPENGL=OFF \
          -DWITH_PNG=OFF \
          -DWITH_PTHREADS_PF=OFF \
          -DWITH_QT=OFF \
          -DWITH_TIFF=OFF \
          -DWITH_V4L=OFF \
          -DWITH_VTK=OFF \
          -DWITH_WEBP=OFF \
          -DWITH_WIN32UI=OFF \
          -DWITH_XINE=OFF .. &&
          $MAKE && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build opencv${NC}"
        return 1
    fi

    cd ../..
}

install_openvino() {
    if [ ! -d "openvino" ] ; then
        git clone https://github.com/openvinotoolkit/openvino
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download Intel DLDT source!${NC}"
            return 1
        fi
        cd openvino
        git checkout releases/2021/1 &&
        git submodule update --init --recursive
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download sub modules for DLDT inference engine!${NC}"
            return 1
        fi
        sed "s/{{mopts}}/${mopts}/g" ${BASEDIR}/openvino.patch | patch -l -p1
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to patch DLDT!${NC}"
            return 1
        fi
    else
        cd openvino
    fi
    mkdir -p build
    cd build
    cmake -DCMAKE_INSTALL_PREFIX=$prefix -DCMAKE_BUILD_TYPE=Release -DTHREADING=SEQ \
          -DCMAKE_SKIP_RPATH=TRUE -DBUILD_TESTS=OFF \
          -DENABLE_GNA=OFF -DENABLE_OBJECT_DETECTION_TESTS=OFF -DENABLE_OPENCV=OFF \
          -DENABLE_PROFILING_ITT=OFF -DENABLE_SAMPLES=OFF -DENABLE_SAMPLES_CORE=OFF \
          -DENABLE_SEGMENTATION_TESTS=OFF -DENABLE_TESTS=OFF \
          -DNGRAPH_UNIT_TEST_ENABLE=OFF -DNGRAPH_TEST_UTIL_ENABLE=OFF .. &&
    $MAKE inference_engine ie_plugins
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build DLDT inference engine!${NC}"
        return 1
    fi
    cd ..
    sudo mkdir -p $prefix/include &&
    sudo cp -r inference-engine/include $prefix/include/openvino &&
    sudo cp -av bin/intel64/Release/lib/libinference_engine.so \
                bin/intel64/Release/lib/libinference_engine_ir_reader.so \
                bin/intel64/Release/lib/libngraph.so \
                bin/intel64/Release/lib/libclDNNPlugin.so \
                bin/intel64/Release/lib/libmyriadPlugin.so \
                bin/intel64/Release/lib/libMKLDNNPlugin.so \
                bin/intel64/Release/lib/cache.json \
                bin/intel64/Release/lib/plugins.xml $prefix/lib
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install inference engine!${NC}"
        return 1
    fi
    cd ..
}

install_cmake &&
install_gperftools &&
install_blas &&
install_protobuf &&
install_abseil_cpp &&
install_tensorflow &&
install_x264 &&
install_ffmpeg &&
install_gflags &&
install_glog &&
install_google_benchmark &&
install_opencv &&
install_openvino &&
sudo ldconfig
