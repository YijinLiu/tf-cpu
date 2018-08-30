#!/bin/bash

RED='\e[0;31m'
GREEN='\e[0;92m'
YELLOW='\e[0;33m'
NC='\e[0m'

ARCH=$(uname -m)

usage() {
    echo "Options:
    --blas=              MKL/OpenBLAS/ATLAS
    --version=           Tensorflow version.
    --bazel_version=     Bazel version.
"
}

blas=MKL
version=1.10.0
bazel_version=0.15.2
prefix=/usr/local
mopts="-march=native"
mkldnn_version=

OPTS=`getopt -n 'build.sh' -o b:,m:,p:,v: -l blas:,version:,bazel_version:,mkldnn_version:,prefix:,mopts: -- "$@"`
rc=$?
if [ $rc != 0 ] ; then
    usage
    exit 1
fi
eval set -- "$OPTS"
while true; do
    case "$1" in
        -b | --blas )               blas="$2" ; shift 2 ;;
        -v | --version )            version="$2" ; shift 2 ;;
        -p | --prefix )             prefix="$2" ; shift 2 ;;
        -m | --mopts )              mopts="$2" ; shift 2 ;;
        --bazel_version )           bazel_version="$2" ; shift 2 ;;
        --mkldnn_version )          mkldnn_version="$2" ; shift 2 ;;
        -- ) shift; break ;;
        * ) echo -e "${RED}Invalid option: -$1${NC}" >&2 ; usage ; exit 1 ;;
    esac
done
echo -e ${GREEN}BLAS: $blas${NC}

blas_pkgs=
case "$blas" in
    OpenBLAS | ATLAS ) blas_pkgs=libgfortran-5-dev
esac

install_deps() {
    sudo apt update &&
    sudo apt install -y --no-install-recommends autoconf automake build-essential cmake cpio curl \
        git libtool openjdk-8-jdk python unzip wget yasm zlib1g-dev $blas_pkgs &&
    sudo apt clean
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install dependant packages!${NC}"
        return 1
    fi
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
    make && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build ATLAS!${NC}"
        return 1
    fi
    cd ../..
}

install_openblas() {
    git clone --depth=1 https://github.com/xianyi/OpenBLAS -b v0.2.19
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to download OpenBLAS source!${NC}"
        return 1
    fi
    cd OpenBLAS
    make USE_THREAD=0 USE_OPENMP=0 -j $(nproc) &&
    sudo make PREFIX=$prefix/OpenBLAS install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to compile OpenBLAS!${NC}"
        return 1
    fi
    cd ..
}

# Visit https://registrationcenter.intel.com/en/products/postregistration/?sn=3VGW-6NPJL6SB
# to find latest versions of MKL and IPP.
install_mkl() {
    prid="13005"
    ver="2018.3.222"
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

install_mkldnn() {
    if [ -z "$mkldnn_version" ] ; then
        return
    fi
    if [ ! -d "mkl-dnn" ] ; then
        git clone --depth=1 https://github.com/intel/mkl-dnn -b v$mkldnn_version
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download mkl-dnn source code!${NC}"
            return 1
        fi
        cd mkl-dnn
        patch -l -p1 <<- EOD
diff --git a/CMakeLists.txt b/CMakeLists.txt
index 048dcfb..0047bab 100644
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -54,7 +54,6 @@ if("\${CMAKE_BUILD_TYPE}" STREQUAL "")
 endif()
 
 include("cmake/platform.cmake")
-include("cmake/OpenMP.cmake")
 include("cmake/SDL.cmake")
 include("cmake/MKL.cmake")
 include("cmake/Doxygen.cmake")
diff --git a/cmake/MKL.cmake b/cmake/MKL.cmake
index 883fb21..efba5ca 100644
--- a/cmake/MKL.cmake
+++ b/cmake/MKL.cmake
@@ -18,167 +18,14 @@
 # \${CMAKE_CURRENT_SOURCE_DIR}/external
 #===============================================================================
 
-if(MKL_cmake_included)
-    return()
-endif()
-set(MKL_cmake_included true)
+set(HAVE_MKL TRUE)
+set(MKLROOT "${prefix}/intel/mkl")
+set(MKLINC "\${MKLROOT}/include")
 
-function(detect_mkl LIBNAME)
-    if(HAVE_MKL)
-        return()
-    endif()
-
-    message(STATUS "Detecting Intel(R) MKL: trying \${LIBNAME}")
-
-    find_path(MKLINC mkl_cblas.h
-        HINTS \${MKLROOT}/include \$ENV{MKLROOT}/include)
-    if(NOT MKLINC)
-        file(GLOB_RECURSE MKLINC
-                \${CMAKE_CURRENT_SOURCE_DIR}/external/*/mkl_cblas.h)
-        if(MKLINC)
-            # if user has multiple version under external/ then guess last
-            # one alphabetically is "latest" and warn
-            list(LENGTH MKLINC MKLINCLEN)
-            if(MKLINCLEN GREATER 1)
-                list(SORT MKLINC)
-                list(REVERSE MKLINC)
-                # message(STATUS "MKLINC found \${MKLINCLEN} files:")
-                # foreach(LOCN IN LISTS MKLINC)
-                #     message(STATUS "       \${LOCN}")
-                # endforeach()
-                list(GET MKLINC 0 MKLINCLST)
-                set(MKLINC "\${MKLINCLST}")
-                # message(WARNING "MKLINC guessing... \${MKLINC}.  "
-                #     "Please check that above dir has the desired mkl_cblas.h")
-            endif()
-            get_filename_component(MKLINC \${MKLINC} PATH)
-        endif()
-    endif()
-    if(NOT MKLINC)
-        return()
-    endif()
-
-    get_filename_component(__mklinc_root "\${MKLINC}" PATH)
-    find_library(MKLLIB NAMES \${LIBNAME}
-        HINTS   \${MKLROOT}/lib \${MKLROOT}/lib/intel64
-                \$ENV{MKLROOT}/lib \$ENV{MKLROOT}/lib/intel64
-                \${__mklinc_root}/lib \${__mklinc_root}/lib/intel64)
-    if(NOT MKLLIB)
-        return()
-    endif()
-
-    if(WIN32)
-        set(MKLREDIST \${MKLINC}/../../redist/)
-        find_file(MKLDLL NAMES \${LIBNAME}.dll
-            HINTS
-                \${MKLREDIST}/mkl
-                \${MKLREDIST}/intel64/mkl
-                \${__mklinc_root}/lib)
-        if(NOT MKLDLL)
-            return()
-        endif()
-    endif()
-
-    if(NOT CMAKE_CXX_COMPILER_ID STREQUAL "Intel")
-        get_filename_component(MKLLIBPATH \${MKLLIB} PATH)
-        find_library(MKLIOMP5LIB
-            NAMES "iomp5" "iomp5md" "libiomp5" "libiomp5md"
-            HINTS   \${MKLLIBPATH}
-                    \${MKLLIBPATH}/../../lib
-                    \${MKLLIBPATH}/../../../lib/intel64
-                    \${MKLLIBPATH}/../../compiler/lib
-                    \${MKLLIBPATH}/../../../compiler/lib/intel64)
-        if(NOT MKLIOMP5LIB)
-            return()
-        endif()
-        if(WIN32)
-            find_file(MKLIOMP5DLL
-                NAMES "libiomp5.dll" "libiomp5md.dll"
-                HINTS \${MKLREDIST}/../compiler \${__mklinc_root}/lib)
-            if(NOT MKLIOMP5DLL)
-                return()
-            endif()
-        endif()
-    else()
-        set(MKLIOMP5LIB)
-        set(MKLIOMP5DLL)
-    endif()
-
-    get_filename_component(MKLLIBPATH "\${MKLLIB}" PATH)
-    string(FIND "\${MKLLIBPATH}" \${CMAKE_CURRENT_SOURCE_DIR}/external __idx)
-    if(\${__idx} EQUAL 0)
-        if(WIN32)
-            install(PROGRAMS \${MKLDLL} DESTINATION lib)
-        else()
-            install(PROGRAMS \${MKLLIB} DESTINATION lib)
-        endif()
-        if(MKLIOMP5LIB)
-            if(WIN32)
-                install(PROGRAMS \${MKLIOMP5DLL} DESTINATION lib)
-            else()
-                install(PROGRAMS \${MKLIOMP5LIB} DESTINATION lib)
-            endif()
-        endif()
-    endif()
-
-    if(WIN32)
-        # Add paths to DLL to %PATH% on Windows
-        get_filename_component(MKLDLLPATH "\${MKLDLL}" PATH)
-        set(CTESTCONFIG_PATH "\${CTESTCONFIG_PATH}\\;\${MKLDLLPATH}")
-        set(CTESTCONFIG_PATH "\${CTESTCONFIG_PATH}" PARENT_SCOPE)
-    endif()
-
-    # TODO: cache the value
-    set(HAVE_MKL TRUE PARENT_SCOPE)
-    set(MKLINC \${MKLINC} PARENT_SCOPE)
-    set(MKLLIB "\${MKLLIB}" PARENT_SCOPE)
-
-    if(WIN32)
-        set(MKLDLL "\${MKLDLL}" PARENT_SCOPE)
-    endif()
-    if(MKLIOMP5LIB)
-        set(MKLIOMP5LIB "\${MKLIOMP5LIB}" PARENT_SCOPE)
-    endif()
-    if(WIN32 AND MKLIOMP5DLL)
-        set(MKLIOMP5DLL "\${MKLIOMP5DLL}" PARENT_SCOPE)
-    endif()
-endfunction()
-
-detect_mkl("mklml_intel")
-detect_mkl("mklml")
-detect_mkl("mkl_rt")
-
-if(HAVE_MKL)
-    add_definitions(-DUSE_MKL -DUSE_CBLAS)
-    include_directories(AFTER \${MKLINC})
-    list(APPEND mkldnn_LINKER_LIBS \${MKLLIB})
-
-    set(MSG "Intel(R) MKL:")
-    message(STATUS "\${MSG} include \${MKLINC}")
-    message(STATUS "\${MSG} lib \${MKLLIB}")
-    if(MKLIOMP5LIB)
-        message(STATUS "\${MSG} OpenMP lib \${MKLIOMP5LIB}")
-    else()
-        message(STATUS "\${MSG} OpenMP lib provided by compiler")
-    endif()
-    if(WIN32)
-        message(STATUS "\${MSG} dll \${MKLDLL}")
-        if(MKLIOMP5DLL)
-            message(STATUS "\${MSG} OpenMP dll \${MKLIOMP5DLL}")
-        else()
-            message(STATUS "\${MSG} OpenMP dll provided by compiler")
-        endif()
-    endif()
-else()
-    if(DEFINED ENV{FAIL_WITHOUT_MKL} OR DEFINED FAIL_WITHOUT_MKL)
-        set(SEVERITY "FATAL_ERROR")
-    else()
-        set(SEVERITY "WARNING")
-    endif()
-    message(\${SEVERITY}
-        "Intel(R) MKL not found. Some performance features may not be "
-        "available. Please run scripts/prepare_mkl.sh to download a minimal "
-        "set of libraries or get a full version from "
-        "https://software.intel.com/en-us/intel-mkl")
-endif()
+add_definitions(-DUSE_MKL -DUSE_CBLAS)
+include_directories(AFTER \${MKLINC})
+list(APPEND EXTRA_LIBS -Wl,--start-group mkl_gf_lp64 mkl_sequential mkl_core -Wl,--end-group pthread dl)
+SET(CMAKE_EXE_LINKER_FLAGS "\${CMAKE_EXE_LINKER_FLAGS} -L${prefix}/intel/mkl/lib")
 
+set(MSG "Intel(R) MKL:")
+message(STATUS "\${MSG} include \${MKLINC}")
diff --git a/cmake/SDL.cmake b/cmake/SDL.cmake
index 12855a7..348037f 100644
--- a/cmake/SDL.cmake
+++ b/cmake/SDL.cmake
@@ -23,7 +23,7 @@ endif()
 set(SDL_cmake_included true)
 
 if(UNIX OR APPLE)
-    set(CMAKE_CCXX_FLAGS "-fPIC -Wformat -Wformat-security")
+    set(CMAKE_CCXX_FLAGS "-Wformat -Wformat-security")
     set(CMAKE_CXX_FLAGS_RELEASE "\${CMAKE_CXX_FLAGS_RELEASE} -D_FORTIFY_SOURCE=2")
     set(CMAKE_C_FLAGS_RELEASE "\${CMAKE_C_FLAGS_RELEASE} -D_FORTIFY_SOURCE=2")
     if("\${CMAKE_CXX_COMPILER_ID}" STREQUAL "GNU")
@@ -43,7 +43,6 @@ if(UNIX OR APPLE)
         set(CMAKE_SHARED_LINKER_FLAGS "\${CMAKE_SHARED_LINKER_FLAGS} -Wl,-bind_at_load")
         set(CMAKE_EXE_LINKER_FLAGS "\${CMAKE_EXE_LINKER_FLAGS} -Wl,-bind_at_load")
     else()
-        set(CMAKE_EXE_LINKER_FLAGS "\${CMAKE_EXE_LINKER_FLAGS} -pie")
         set(CMAKE_SHARED_LINKER_FLAGS "\${CMAKE_SHARED_LINKER_FLAGS} -Wl,-z,noexecstack -Wl,-z,relro -Wl,-z,now")
         set(CMAKE_EXE_LINKER_FLAGS "\${CMAKE_EXE_LINKER_FLAGS} -Wl,-z,noexecstack -Wl,-z,relro -Wl,-z,now")
     endif()
diff --git a/cmake/platform.cmake b/cmake/platform.cmake
index faabc5d..4b3fa88 100644
--- a/cmake/platform.cmake
+++ b/cmake/platform.cmake
@@ -67,7 +67,7 @@ elseif(UNIX OR APPLE)
         set(CMAKE_CCXX_FLAGS "\${CMAKE_CCXX_FLAGS} -Wno-pass-failed")
     elseif("\${CMAKE_CXX_COMPILER_ID}" STREQUAL "GNU")
         if(NOT CMAKE_CXX_COMPILER_VERSION VERSION_LESS 5.0)
-            set(DEF_ARCH_OPT_FLAGS "-march=native -mtune=native")
+            set(DEF_ARCH_OPT_FLAGS "$mopts")
         endif()
         if(CMAKE_CXX_COMPILER_VERSION VERSION_LESS 6.0)
             # suppress warning on assumptions made regarding overflow (#146)
diff --git a/examples/CMakeLists.txt b/examples/CMakeLists.txt
index a65617c..27863c5 100644
--- a/examples/CMakeLists.txt
+++ b/examples/CMakeLists.txt
@@ -18,7 +18,7 @@ include_directories(\${CMAKE_SOURCE_DIR}/include)
 
 add_executable(simple-net-c simple_net.c)
 set_property(TARGET simple-net-c PROPERTY C_STANDARD 99)
-target_link_libraries(simple-net-c \${LIB_NAME})
+target_link_libraries(simple-net-c \${LIB_NAME} \${EXTRA_LIBS})
 add_test(simple-net-c simple-net-c)
 if(WIN32)
     configure_file(\${CMAKE_SOURCE_DIR}/config_template.vcxproj.user
@@ -28,7 +28,7 @@ endif()
 
 add_executable(simple-net-cpp simple_net.cpp)
 set_property(TARGET simple-net-cpp PROPERTY CXX_STANDARD 11)
-target_link_libraries(simple-net-cpp \${LIB_NAME})
+target_link_libraries(simple-net-cpp \${LIB_NAME} \${EXTRA_LIBS})
 add_test(simple-net-cpp simple-net-cpp)
 if(WIN32)
     configure_file(\${CMAKE_SOURCE_DIR}/config_template.vcxproj.user
@@ -41,7 +41,7 @@ set_property(TARGET simple-training-net-c PROPERTY C_STANDARD 99)
 if(WIN32)
 target_link_libraries(simple-training-net-c \${LIB_NAME})
 else()
-target_link_libraries(simple-training-net-c \${LIB_NAME} m)
+target_link_libraries(simple-training-net-c \${LIB_NAME} \${EXTRA_LIBS} m)
 endif()
 add_test(simple-training-net-c simple-training-net-c)
 if(WIN32)
@@ -55,7 +55,7 @@ set_property(TARGET simple-training-net-cpp PROPERTY CXX_STANDARD 11)
 if(WIN32)
 target_link_libraries(simple-training-net-cpp \${LIB_NAME})
 else()
-target_link_libraries(simple-training-net-cpp \${LIB_NAME} m)
+target_link_libraries(simple-training-net-cpp \${LIB_NAME} \${EXTRA_LIBS} m)
 endif()
 add_test(simple-training-net-cpp simple-training-net-cpp)
 if(WIN32)
@@ -66,7 +66,11 @@ endif()
 
 add_executable(simple-net-int8-cpp simple_net_int8.cpp)
 set_property(TARGET simple-net-int8-cpp PROPERTY CXX_STANDARD 11)
+if(WIN32)
 target_link_libraries(simple-net-int8-cpp \${LIB_NAME})
+else()
+target_link_libraries(simple-net-int8-cpp \${LIB_NAME} \${EXTRA_LIBS})
+endif()
 add_test(simple-net-int8-cpp simple-net-int8-cpp)
 if(WIN32)
     configure_file(\${CMAKE_SOURCE_DIR}/config_template.vcxproj.user
diff --git a/src/CMakeLists.txt b/src/CMakeLists.txt
index 2393323..633588a 100644
--- a/src/CMakeLists.txt
+++ b/src/CMakeLists.txt
@@ -46,7 +46,7 @@ if(WIN32)
     endif()
 endif()
 
-add_library(\${TARGET_NAME} SHARED \${HEADERS} \${SOURCES})
+add_library(\${TARGET_NAME} STATIC \${HEADERS} \${SOURCES})
 #Add mkldnn.dll to execution PATH
 set(CTESTCONFIG_PATH "\${CTESTCONFIG_PATH}\\;\${CMAKE_CURRENT_BINARY_DIR}/\${CMAKE_BUILD_TYPE}" PARENT_SCOPE)
 target_link_libraries(\${TARGET_NAME} \${\${TARGET_NAME}_LINKER_LIBS} \${EXTRA_LIBS})
EOD
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to patch MKL-DNN!${NC}"
            return 1
        fi
    else
        cd mkl-dnn
    fi
    mkdir -p build && cd build &&
    cmake -DCMAKE_INSTALL_PREFIX=$prefix/intel/mkldnn -DCMAKE_BUILD_TYPE=Release .. &&
    make -j$(nproc) && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build MKL-DNN!${NC}"
        return 1
    fi
    cd ../..
}

install_blas() {
    case "$blas" in
        "ATLAS" ) install_atlas ;;
        "OpenBLAS" ) install_openblas ;;
        "MKL" ) install_mkl && install_mkldnn ;;
        * ) echo -e "${YELLOW}No BLAS will be install.${NC}"
    esac
}

install_eigen() {
    # Tensorflow needs some latest changes.
    # TODO: Switch to release after there is a new one.
    # See tensorflow/workspace.bzl for what's the version used by tensorflow.
    eigen_tag=fd6845384b86
    if [ ! -d "eigen-eigen-$eigen_tag" ]; then
        wget -O eigen-${eigen_tag}.tar.gz https://bitbucket.org/eigen/eigen/get/${eigen_tag}.tar.gz &&
        tar xvf eigen-${eigen_tag}.tar.gz
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download eigen!${NC}"
            return 1
        fi
    fi
    cd eigen-eigen-${eigen_tag}
    mkdir build
    cd build
    cmake -DCMAKE_INSTALL_PREFIX=$prefix .. && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install eigen!${NC}"
        return 1
    fi
    cd ../..
}

install_protobuf() {
    if [ ! -d "protobuf" ]; then
        git clone --depth=1 https://github.com/google/protobuf -b v3.5.1
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
    ./configure --enable-static --disable-shared $opts --prefix=${prefix} &&
    make -j$(nproc) && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build protobuf${NC}"
        return 1
    fi
    cd ..
}

install_flatbuffers() {
    if [ ! -d "flatbuffers" ]; then
        git clone --depth=1 https://github.com/google/flatbuffers -b v1.9.0
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download flatbuffers.${NC}"
            return 1
        fi
    fi

    cd flatbuffers
    mkdir -p build
    cd build
    cmake -DCMAKE_INSTALL_PREFIX=$prefix .. &&
    make -j$(nproc) && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build flatbuffers${NC}"
        return 1
    fi
    cd ../..
}

install_headers() {
    src=$1
    dst=$2
    for header in $(find $src -name "*.h") ; do
        dir=$(dirname $header)
        sudo mkdir -p $dst/$dir && sudo cp $header $dst/$dir/
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to install $header!${NC}"
            return 1
        fi
    done
}

install_gemmlowp() {
    if [ ! -d "gemmlowp" ] ; then
        git clone --depth=1 https://github.com/google/gemmlowp
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download gemmlowp.${NC}"
            return 1
        fi
    fi
    install_headers gemmlowp/public $prefix/include &&
    install_headers gemmlowp/internal $prefix/include &&
    install_headers gemmlowp/profiling $prefix/include &&
    install_headers gemmlowp/fixedpoint $prefix/include &&
    install_headers gemmlowp/meta $prefix/include
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install gemmlowp.${NC}"
        return 1
    fi
}

install_nsync() {
    if [ ! -d "nsync" ] ; then
        git clone --depth=1 https://github.com/google/nsync
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download nsync.${NC}"
            return 1
        fi
        cd nsync
        patch -l -p1 <<- EOD
diff --git a/CMakeLists.txt b/CMakeLists.txt
index 0636189..a8992d3 100644
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -8,7 +8,7 @@ project (nsync)
 # rather than C.

 # Some builds need position-independent code.
-set (CMAKE_POSITION_INDEPENDENT_CODE ON)
+set (CMAKE_POSITION_INDEPENDENT_CODE OFF)

 # -----------------------------------------------------------------
 # Platform dependencies
EOD
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to patch nsync!${NC}"
            return 1
        fi
    else
        cd nsync
    fi
    mkdir -p build
    cd build
    cmake -DCMAKE_INSTALL_PREFIX=$prefix -DNSYNC_LANGUAGE=c++11 .. &&
    make -j$(nproc) && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed build nsync.${NC}"
        return 1
    fi
    cd ../..
}

install_farmhash() {
    if [ ! -d "farmhash" ] ; then
        git clone --depth=1 https://github.com/google/farmhash
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download farmhash.${NC}"
            return 1
        fi
    fi
    cd farmhash
    aclocal && automake --add-missing &&
    ./configure --prefix=$prefix --enable-shared=no --enable-static=yes &&
    make -j$(nproc) && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install farmhash.${NC}"
        return 1
    fi
    cd ..
}

install_double_conversion() {
    if [ ! -d "double-conversion" ] ; then
        git clone --depth=1 https://github.com/google/double-conversion
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download double-conversion.${NC}"
            return 1
        fi
    fi
    cd double-conversion
    mkdir -p build
    cd build
    cmake -DCMAKE_INSTALL_PREFIX=$prefix .. &&
    make -j$(nproc) && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build flatbuffers${NC}"
        return 1
    fi
    cd ../..
}

install_neon2sse() {
    if [ ! -d "ARM_NEON_2_x86_SSE" ] ; then
        git clone --depth=1 https://github.com/intel/ARM_NEON_2_x86_SSE ARM_NEON_2_x86_SSE
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download ARM_NEON_2_x86_SSE.${NC}"
            return 1
        fi
    fi
    cd ARM_NEON_2_x86_SSE
    mkdir -p build
    cd build
    cmake -DCMAKE_INSTALL_PREFIX=$prefix .. && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install ARM_NEON_2_x86_SSE.${NC}"
        return 1
    fi
    cd ../..
}

install_bazel() {
    if [ ! -f bazel_${bazel_version}-linux-x86_64.deb ] ; then
        wget -O bazel_${bazel_version}-linux-x86_64.deb https://github.com/bazelbuild/bazel/releases/download/${bazel_version}/bazel_${bazel_version}-linux-x86_64.deb
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download Bazel!${NC}"
            return 1
        fi
    fi
    sudo dpkg -i bazel_${bazel_version}-linux-x86_64.deb
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install Bazel!${NC}"
        return 1
    fi
}

mkl_cxxflags="-DINTEL_MKL -DEIGEN_USE_MKL_ALL -DMKL_DIRECT_CALL -I${prefix}/intel/mkl/include -I${prefix}/intel/mkldnn/include"
mkl_ldflags="-L${prefix}/intel/mkl/lib -Wl,--start-group -lmkl_intel_lp64 -lmkl_sequential -lmkl_core -Wl,--end-group"
if [ -z "$mkldnn_version" ] ; then
    mkl_cxxflags="${mkl_cxxflags} -DINTEL_MKL_ML"
else
    mkl_ldflags="-L${prefix}/intel/mkldnn/lib/ -lmkldnn ${mkl_ldflags}"
fi

install_tensorflow() {
    if [ ! -d tensorflow ] ; then
        git clone --depth=1 https://github.com/tensorflow/tensorflow -b v${version}
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download TensorFlow source!${NC}"
            return 1
        fi
        cd tensorflow
        patch -l -p1 <<- EOD
diff --git a/tensorflow/cc/gradients/math_grad.cc b/tensorflow/cc/gradients/math_grad.cc
index 35a01e0..851937e 100644
--- a/tensorflow/cc/gradients/math_grad.cc
+++ b/tensorflow/cc/gradients/math_grad.cc
@@ -265,6 +265,16 @@ Status SigmoidGrad(const Scope& scope, const Operation& op,
 }
 REGISTER_GRADIENT_OP("Sigmoid", SigmoidGrad);
 
+Status SigmoidWithCrossEntropyLossGrad(const Scope& scope,
+                                       const Operation& op,
+                                       const std::vector<Output>& grad_inputs,
+                                       std::vector<Output>* grad_outputs) {
+  grad_outputs->push_back(SimpleLossGrad(scope, op.output(1), op.input(1)));
+  grad_outputs->push_back(Identity(scope, grad_inputs[0]));
+  return scope.status();
+}
+REGISTER_GRADIENT_OP("SigmoidWithCrossEntropyLoss", SigmoidWithCrossEntropyLossGrad);
+
 Status SignGrad(const Scope& scope, const Operation& op,
                 const std::vector<Output>& grad_inputs,
                 std::vector<Output>* grad_outputs) {
diff --git a/tensorflow/cc/gradients/nn_grad.cc b/tensorflow/cc/gradients/nn_grad.cc
index c73482d..871678a 100644
--- a/tensorflow/cc/gradients/nn_grad.cc
+++ b/tensorflow/cc/gradients/nn_grad.cc
@@ -59,6 +59,16 @@ Status LogSoftmaxGrad(const Scope& scope, const Operation& op,
 }
 REGISTER_GRADIENT_OP("LogSoftmax", LogSoftmaxGrad);
 
+Status SoftmaxWithLogLikelihoodLossGrad(const Scope& scope,
+                                        const Operation& op,
+                                        const std::vector<Output>& grad_inputs,
+                                        std::vector<Output>* grad_outputs) {
+  grad_outputs->push_back(SimpleLossGrad(scope, op.output(1), op.input(1)));
+  grad_outputs->push_back(Identity(scope, grad_inputs[0]));
+  return scope.status();
+}
+REGISTER_GRADIENT_OP("SoftmaxWithLogLikelihoodLoss", SoftmaxWithLogLikelihoodLossGrad);
+
 Status ReluGradHelper(const Scope& scope, const Operation& op,
                       const std::vector<Output>& grad_inputs,
                       std::vector<Output>* grad_outputs) {
diff --git a/tensorflow/contrib/lite/Makefile b/tensorflow/contrib/lite/Makefile
index df59547..f5f1aa0 100644
--- a/tensorflow/contrib/lite/Makefile
+++ b/tensorflow/contrib/lite/Makefile
@@ -1,3 +1,5 @@
+SHELL := /bin/bash
+
 # Find where we're running from, so we can store generated files here.
 ifeq (\$(origin MAKEFILE_DIR), undefined)
 	MAKEFILE_DIR := \$(shell dirname \$(realpath \$(lastword \$(MAKEFILE_LIST))))
@@ -82,9 +84,9 @@ endif
 
 # Settings for the host compiler.
 CXX := \$(CC_PREFIX) \${TARGET_TOOLCHAIN_PREFIX}g++
-CXXFLAGS += -O3 -DNDEBUG
+CXXFLAGS += -O3 -DNDEBUG ${mopts}
 CCFLAGS := \${CXXFLAGS}
-CXXFLAGS += --std=c++11
+CXXFLAGS += --std=c++11 -DEIGEN_DONT_PARALLELIZE -DEIGEN_USE_VML -DEIGEN_AVOID_STL_ARRAY
 CC := \$(CC_PREFIX) \${TARGET_TOOLCHAIN_PREFIX}gcc
 AR := \$(CC_PREFIX) \${TARGET_TOOLCHAIN_PREFIX}ar
 CFLAGS :=
@@ -92,25 +94,9 @@ LDOPTS :=
 LDOPTS += -L/usr/local/lib
 ARFLAGS := -r
 
-INCLUDES := \\
--I. \\
--I\$(MAKEFILE_DIR)/../../../ \\
--I\$(MAKEFILE_DIR)/downloads/ \\
--I\$(MAKEFILE_DIR)/downloads/eigen \\
--I\$(MAKEFILE_DIR)/downloads/gemmlowp \\
--I\$(MAKEFILE_DIR)/downloads/neon_2_sse \\
--I\$(MAKEFILE_DIR)/downloads/farmhash/src \\
--I\$(MAKEFILE_DIR)/downloads/flatbuffers/include \\
--I\$(GENDIR)
-# This is at the end so any globally-installed frameworks like protobuf don't
-# override local versions in the source tree.
-INCLUDES += -I/usr/local/include
-
-LIBS += \\
--lstdc++ \\
--lpthread \\
--lm \\
--lz
+INCLUDES := -I. -I\$(MAKEFILE_DIR)/../../../ -I${prefix}/include -I${prefix}/include/eigen3 -I${prefix}/include/gemmlowp
+
+LIBS := -lfarmhash -lstdc++ -lpthread -lm -lz
 
 # If we're on Linux, also link in the dl library.
 ifeq (\$(HOST_OS),LINUX)
@@ -172,7 +158,8 @@ \$(wildcard tensorflow/contrib/lite/*test.cc) \\
 \$(wildcard tensorflow/contrib/lite/*/*test.cc) \\
 \$(wildcard tensorflow/contrib/lite/*/*/*test.cc) \\
 \$(wildcard tensorflow/contrib/lite/*/*/*/*test.cc) \\
-\$(wildcard tensorflow/contrib/lite/kernels/test_util.cc) \\
+tensorflow/contrib/lite/kernels/internal/spectrogram.cc \\
+tensorflow/contrib/lite/kernels/test_util.cc \\
 \$(MINIMAL_SRCS)
 ifeq (\$(BUILD_TYPE),micro)
 CORE_CC_EXCLUDE_SRCS += \\
@@ -209,7 +196,7 @@ \$(OBJDIR)%.o: %.c
 	\$(CC) \$(CCFLAGS) \$(INCLUDES) -c \$< -o \$@
 
 # The target that's compiled if there's no command-line arguments.
-all: \$(LIB_PATH)  \$(MINIMAL_PATH) \$(BENCHMARK_BINARY)
+all: \$(LIB_PATH)
 
 # The target that's compiled for micro-controllers
 micro: \$(LIB_PATH)
diff --git a/tensorflow/contrib/lite/interpreter.cc b/tensorflow/contrib/lite/interpreter.cc
index d103786..1f560da 100644
--- a/tensorflow/contrib/lite/interpreter.cc
+++ b/tensorflow/contrib/lite/interpreter.cc
@@ -20,6 +20,8 @@ limitations under the License.
 #include <cstdint>
 #include <cstring>
 
+#include <Eigen/Core>
+
 #include "tensorflow/contrib/lite/arena_planner.h"
 #include "tensorflow/contrib/lite/context.h"
 #include "tensorflow/contrib/lite/context_util.h"
diff --git a/tensorflow/contrib/lite/kernels/register.cc b/tensorflow/contrib/lite/kernels/register.cc
index 22a507e..c3dd680 100644
--- a/tensorflow/contrib/lite/kernels/register.cc
+++ b/tensorflow/contrib/lite/kernels/register.cc
@@ -195,8 +195,6 @@ BuiltinOpResolver::BuiltinOpResolver() {
   // TODO(andrewharp, ahentz): Move these somewhere more appropriate so that
   // custom ops aren't always included by default.
   AddCustom("Mfcc", tflite::ops::custom::Register_MFCC());
-  AddCustom("AudioSpectrogram",
-            tflite::ops::custom::Register_AUDIO_SPECTROGRAM());
   AddCustom("TFLite_Detection_PostProcess",
             tflite::ops::custom::Register_DETECTION_POSTPROCESS());
 }
diff --git a/tensorflow/contrib/lite/nnapi/NeuralNetworksShim.h b/tensorflow/contrib/lite/nnapi/NeuralNetworksShim.h
index becd1f6..b8f3f8c 100644
--- a/tensorflow/contrib/lite/nnapi/NeuralNetworksShim.h
+++ b/tensorflow/contrib/lite/nnapi/NeuralNetworksShim.h
@@ -61,8 +61,12 @@ inline void* loadFunction(const char* name) {
 }
 
 inline bool NNAPIExists() {
+#ifdef __ANDROID__
   static bool nnapi_is_available = getLibraryHandle();
   return nnapi_is_available;
+#else
+  return false;
+#endif
 }
 
 // NN api types based on NNAPI header file
diff --git a/tensorflow/contrib/makefile/Makefile b/tensorflow/contrib/makefile/Makefile
index 1a1ab54..11c598f 100644
--- a/tensorflow/contrib/makefile/Makefile
+++ b/tensorflow/contrib/makefile/Makefile
@@ -81,16 +81,7 @@ ifeq (\$(HAS_GEN_HOST_PROTOC),true)
 endif
 HOST_LDOPTS += -L/usr/local/lib
 
-HOST_INCLUDES := \\
--I. \\
--I\$(MAKEFILE_DIR)/../../../ \\
--I\$(MAKEFILE_DIR)/downloads/ \\
--I\$(MAKEFILE_DIR)/downloads/eigen \\
--I\$(MAKEFILE_DIR)/downloads/gemmlowp \\
--I\$(MAKEFILE_DIR)/downloads/nsync/public \\
--I\$(MAKEFILE_DIR)/downloads/fft2d \\
--I\$(MAKEFILE_DIR)/downloads/double_conversion \\
--I\$(HOST_GENDIR)
+HOST_INCLUDES := -I. -I\$(MAKEFILE_DIR)/../../.. -I\$(HOST_GENDIR) -I${prefix}/include/eigen3 -I${prefix}/include/gemmlowp
 ifeq (\$(HAS_GEN_HOST_PROTOC),true)
 	HOST_INCLUDES += -I\$(MAKEFILE_DIR)/gen/protobuf-host/include
 endif
@@ -98,13 +89,7 @@ endif
 # override local versions in the source tree.
 HOST_INCLUDES += -I/usr/local/include
 
-HOST_LIBS := \\
-\$(HOST_NSYNC_LIB) \\
--lstdc++ \\
--lprotobuf \\
--lpthread \\
--lm \\
--lz
+HOST_LIBS := -lnsync_cpp -lnsync -ldouble-conversion -lstdc++ -lprotobuf -lpthread -lm -lz
 
 # If we're on Linux, also link in the dl library.
 ifeq (\$(HOST_OS),LINUX)
@@ -153,30 +138,29 @@ PBTGENDIR := \$(GENDIR)proto_text/
 PROTOGENDIR := \$(GENDIR)proto/
 DEPDIR := \$(GENDIR)dep/
 \$(shell mkdir -p \$(DEPDIR) >/dev/null)
+ 
+BLAS?=MKL
+BLAS_CXX_FLAGS/ATLAS:=-DEIGEN_USE_BLAS -DEIGEN_USE_LAPACKE
+BLAS_CXX_FLAGS/OpenBLAS:=-DEIGEN_USE_BLAS -DEIGEN_USE_LAPACKE
+BLAS_CXX_FLAGS/MKL:=${mkl_cxxflags} -fexceptions
+BLAS_LD_FLAGS/ATLAS:=-L${prefix}/ATLAS/lib -llapack -lcblas -lf77blas -latlas -lgfortran -lquadmath
+BLAS_LD_FLAGS/OpenBLAS:=-L${prefix}/OpenBLAS/lib -lopenblas -lgfortran -lquadmath
+# See https://software.intel.com/en-us/articles/intel-mkl-link-line-advisor/
+BLAS_LD_FLAGS/MKL:=${mkl_ldflags}
 
 # Settings for the target compiler.
 CXX := \$(CC_PREFIX) gcc
-OPTFLAGS := -O2
+OPTFLAGS := -O3 \$(BLAS_CXX_FLAGS/\$(BLAS)) -DEIGEN_DONT_PARALLELIZE -DEIGEN_USE_VML -DEIGEN_AVOID_STL_ARRAY
 
 ifneq (\$(TARGET),ANDROID)
-   OPTFLAGS += -march=native
+   OPTFLAGS += $mopts
 endif
 
-CXXFLAGS := --std=c++11 -DIS_SLIM_BUILD -fno-exceptions -DNDEBUG \$(OPTFLAGS)
-LDFLAGS := \\
--L/usr/local/lib
+CXXFLAGS := --std=c++11 -g1 -DIS_SLIM_BUILD -fno-exceptions -DNDEBUG \$(OPTFLAGS)
+LDFLAGS := -L${prefix}/lib
 DEPFLAGS = -MT \$@ -MMD -MP -MF \$(DEPDIR)/\$*.Td
 
-INCLUDES := \\
--I. \\
--I\$(MAKEFILE_DIR)/downloads/ \\
--I\$(MAKEFILE_DIR)/downloads/eigen \\
--I\$(MAKEFILE_DIR)/downloads/gemmlowp \\
--I\$(MAKEFILE_DIR)/downloads/nsync/public \\
--I\$(MAKEFILE_DIR)/downloads/fft2d \\
--I\$(MAKEFILE_DIR)/downloads/double_conversion \\
--I\$(PROTOGENDIR) \\
--I\$(PBTGENDIR)
+INCLUDES := -I. -I\$(PROTOGENDIR) -Ibazel-genfiles -I\$(PBTGENDIR) -I${prefix}/include/eigen3 -I${prefix}/include/gemmlowp
 ifeq (\$(HAS_GEN_HOST_PROTOC),true)
 	INCLUDES += -I\$(MAKEFILE_DIR)/gen/protobuf-host/include
 endif
@@ -184,12 +168,7 @@ endif
 # override local versions in the source tree.
 INCLUDES += -I/usr/local/include
 
-LIBS := \\
-\$(TARGET_NSYNC_LIB) \\
--lstdc++ \\
--lprotobuf \\
--lz \\
--lm
+LIBS := \$(BLAS_LD_FLAGS/\$(BLAS)) -lnsync_cpp -lnsync -ldouble-conversion -lstdc++ -lprotobuf -lz -lm
 
 ifeq (\$(HAS_GEN_HOST_PROTOC),true)
 	PROTOC := \$(MAKEFILE_DIR)/gen/protobuf-host/bin/protoc
@@ -219,7 +198,6 @@ ifeq (\$(HAS_GEN_HOST_PROTOC),true)
 	LIBFLAGS += -L\$(MAKEFILE_DIR)/gen/protobuf-host/lib
 	export LD_LIBRARY_PATH=\$(MAKEFILE_DIR)/gen/protobuf-host/lib
 endif
-	CXXFLAGS += -fPIC
 	LIBFLAGS += -Wl,--allow-multiple-definition -Wl,--whole-archive
 	LDFLAGS := -Wl,--no-whole-archive
 endif
@@ -336,7 +314,7 @@ \$(MARCH_OPTION) \\
 -I\$(PBTGENDIR)
 
 	LIBS := \\
-\$(TARGET_NSYNC_LIB) \\
+-lnsync \\
 -lgnustl_static \\
 -lprotobuf \\
 -llog \\
@@ -682,10 +660,187 @@ endif  # TEGRA
 # Filter out all the excluded files.
 TF_CC_SRCS := \$(filter-out \$(CORE_CC_EXCLUDE_SRCS), \$(CORE_CC_ALL_SRCS))
 # Add in any extra files that don't fit the patterns easily
-TF_CC_SRCS += tensorflow/contrib/makefile/downloads/fft2d/fftsg.c
-TF_CC_SRCS += tensorflow/core/common_runtime/gpu/gpu_id_manager.cc
 # Also include the op and kernel definitions.
-TF_CC_SRCS += \$(shell cat \$(MAKEFILE_DIR)/tf_op_files.txt)
+TF_CC_SRCS += tensorflow/core/kernels/aggregate_ops.cc \\
+              tensorflow/core/kernels/argmax_op.cc \\
+              tensorflow/core/kernels/avgpooling_op.cc \\
+              tensorflow/core/kernels/bcast_ops.cc \\
+              tensorflow/core/kernels/bias_op.cc \\
+              tensorflow/core/kernels/cast_op.cc \\
+              tensorflow/core/kernels/cast_op_impl_bfloat.cc \\
+              tensorflow/core/kernels/cast_op_impl_bool.cc \\
+              tensorflow/core/kernels/cast_op_impl_complex128.cc \\
+              tensorflow/core/kernels/cast_op_impl_complex64.cc \\
+              tensorflow/core/kernels/cast_op_impl_double.cc \\
+              tensorflow/core/kernels/cast_op_impl_float.cc \\
+              tensorflow/core/kernels/cast_op_impl_half.cc \\
+              tensorflow/core/kernels/cast_op_impl_int16.cc \\
+              tensorflow/core/kernels/cast_op_impl_int32.cc \\
+              tensorflow/core/kernels/cast_op_impl_int64.cc \\
+              tensorflow/core/kernels/cast_op_impl_int8.cc \\
+              tensorflow/core/kernels/cast_op_impl_uint16.cc \\
+              tensorflow/core/kernels/cast_op_impl_uint8.cc \\
+              tensorflow/core/kernels/concat_op.cc \\
+              tensorflow/core/kernels/concat_lib_cpu.cc \\
+              tensorflow/core/kernels/constant_op.cc \\
+              tensorflow/core/kernels/conv_ops.cc \\
+              tensorflow/core/kernels/conv_ops_using_gemm.cc \\
+              tensorflow/core/kernels/crop_and_resize_op.cc \\
+              tensorflow/core/kernels/cwise_ops_common.cc \\
+              tensorflow/core/kernels/cwise_op_add_1.cc \\
+              tensorflow/core/kernels/cwise_op_add_2.cc \\
+              tensorflow/core/kernels/cwise_op_div.cc \\
+              tensorflow/core/kernels/cwise_op_equal_to_1.cc \\
+              tensorflow/core/kernels/cwise_op_equal_to_2.cc \\
+              tensorflow/core/kernels/cwise_op_exp.cc \\
+              tensorflow/core/kernels/cwise_op_greater.cc \\
+              tensorflow/core/kernels/cwise_op_greater_equal.cc \\
+              tensorflow/core/kernels/cwise_op_less.cc \\
+              tensorflow/core/kernels/cwise_op_logical_and.cc \\
+              tensorflow/core/kernels/cwise_op_maximum.cc \\
+              tensorflow/core/kernels/cwise_op_minimum.cc \\
+              tensorflow/core/kernels/cwise_op_mul_1.cc \\
+              tensorflow/core/kernels/cwise_op_mul_2.cc \\
+              tensorflow/core/kernels/cwise_op_neg.cc \\
+              tensorflow/core/kernels/cwise_op_reciprocal.cc \\
+              tensorflow/core/kernels/cwise_op_round.cc \\
+              tensorflow/core/kernels/cwise_op_rsqrt.cc \\
+              tensorflow/core/kernels/cwise_op_select.cc \\
+              tensorflow/core/kernels/cwise_op_sigmoid.cc \\
+              tensorflow/core/kernels/cwise_op_sqrt.cc \\
+              tensorflow/core/kernels/cwise_op_sub.cc \\
+              tensorflow/core/kernels/control_flow_ops.cc \\
+              tensorflow/core/kernels/deep_conv2d.cc \\
+              tensorflow/core/kernels/dense_update_ops.cc \\
+              tensorflow/core/kernels/depthwise_conv_op.cc \\
+              tensorflow/core/kernels/fake_quant_ops.cc \\
+              tensorflow/core/kernels/fill_functor.cc \\
+              tensorflow/core/kernels/function_ops.cc \\
+              tensorflow/core/kernels/functional_ops.cc \\
+              tensorflow/core/kernels/fused_batch_norm_op.cc \\
+              tensorflow/core/kernels/gather_op.cc \\
+              tensorflow/core/kernels/identity_op.cc \\
+              tensorflow/core/kernels/logging_ops.cc \\
+              tensorflow/core/kernels/matmul_op.cc \\
+              tensorflow/core/kernels/maxpooling_op.cc \\
+              tensorflow/core/kernels/meta_support.cc \\
+              tensorflow/core/kernels/neon/neon_depthwise_conv_op.cc \\
+              tensorflow/core/kernels/non_max_suppression_op.cc \\
+              tensorflow/core/kernels/no_op.cc \\
+              tensorflow/core/kernels/one_hot_op.cc \\
+              tensorflow/core/kernels/ops_util.cc \\
+              tensorflow/core/kernels/pack_op.cc \\
+              tensorflow/core/kernels/pad_op.cc \\
+              tensorflow/core/kernels/parameterized_truncated_normal_op.cc \\
+              tensorflow/core/kernels/pooling_ops_common.cc \\
+              tensorflow/core/kernels/quantized_bias_add_op.cc \\
+              tensorflow/core/kernels/quantization_utils.cc \\
+              tensorflow/core/kernels/random_op.cc \\
+              tensorflow/core/kernels/reduction_ops_all.cc \\
+              tensorflow/core/kernels/reduction_ops_common.cc \\
+              tensorflow/core/kernels/reduction_ops_max.cc \\
+              tensorflow/core/kernels/reduction_ops_mean.cc \\
+              tensorflow/core/kernels/reduction_ops_sum.cc \\
+              tensorflow/core/kernels/relu_op.cc \\
+              tensorflow/core/kernels/reshape_op.cc \\
+              tensorflow/core/kernels/resize_bilinear_op.cc \\
+              tensorflow/core/kernels/sequence_ops.cc \\
+              tensorflow/core/kernels/shape_ops.cc \\
+              tensorflow/core/kernels/slice_op.cc \\
+              tensorflow/core/kernels/slice_op_cpu_impl_1.cc \\
+              tensorflow/core/kernels/slice_op_cpu_impl_2.cc \\
+              tensorflow/core/kernels/slice_op_cpu_impl_3.cc \\
+              tensorflow/core/kernels/slice_op_cpu_impl_4.cc \\
+              tensorflow/core/kernels/slice_op_cpu_impl_5.cc \\
+              tensorflow/core/kernels/slice_op_cpu_impl_6.cc \\
+              tensorflow/core/kernels/slice_op_cpu_impl_7.cc \\
+              tensorflow/core/kernels/snapshot_op.cc \\
+              tensorflow/core/kernels/softmax_op.cc \\
+              tensorflow/core/kernels/split_lib_cpu.cc \\
+              tensorflow/core/kernels/split_op.cc \\
+              tensorflow/core/kernels/strided_slice_op.cc \\
+              tensorflow/core/kernels/strided_slice_op_inst_0.cc \\
+              tensorflow/core/kernels/strided_slice_op_inst_7.cc \\
+              tensorflow/core/kernels/strided_slice_op_inst_6.cc \\
+              tensorflow/core/kernels/strided_slice_op_inst_5.cc \\
+              tensorflow/core/kernels/strided_slice_op_inst_4.cc \\
+              tensorflow/core/kernels/strided_slice_op_inst_3.cc \\
+              tensorflow/core/kernels/strided_slice_op_inst_2.cc \\
+              tensorflow/core/kernels/strided_slice_op_inst_1.cc \\
+              tensorflow/core/kernels/tensor_array.cc \\
+              tensorflow/core/kernels/tensor_array_ops.cc \\
+              tensorflow/core/kernels/tile_functor_cpu.cc \\
+              tensorflow/core/kernels/tile_ops.cc \\
+              tensorflow/core/kernels/tile_ops_cpu_impl_1.cc \\
+              tensorflow/core/kernels/tile_ops_cpu_impl_2.cc \\
+              tensorflow/core/kernels/tile_ops_cpu_impl_3.cc \\
+              tensorflow/core/kernels/tile_ops_cpu_impl_4.cc \\
+              tensorflow/core/kernels/tile_ops_cpu_impl_5.cc \\
+              tensorflow/core/kernels/tile_ops_cpu_impl_6.cc \\
+              tensorflow/core/kernels/tile_ops_cpu_impl_7.cc \\
+              tensorflow/core/kernels/topk_op.cc \\
+              tensorflow/core/kernels/training_ops.cc \\
+              tensorflow/core/kernels/training_op_helpers.cc \\
+              tensorflow/core/kernels/transpose_functor_cpu.cc \\
+              tensorflow/core/kernels/transpose_op.cc \\
+              tensorflow/core/kernels/unpack_op.cc \\
+              tensorflow/core/kernels/variable_ops.cc \\
+              tensorflow/core/kernels/where_op.cc \\
+              tensorflow/core/kernels/xent_op.cc \\
+              tensorflow/core/ops/array_ops.cc \\
+              tensorflow/core/ops/control_flow_ops.cc \\
+              tensorflow/core/ops/data_flow_ops.cc \\
+              tensorflow/core/ops/function_ops.cc \\
+              tensorflow/core/ops/functional_ops.cc \\
+              tensorflow/core/ops/image_ops.cc \\
+              tensorflow/core/ops/logging_ops.cc \\
+              tensorflow/core/ops/math_ops.cc \\
+              tensorflow/core/ops/nn_ops.cc \\
+              tensorflow/core/ops/no_op.cc \\
+              tensorflow/core/ops/random_ops.cc \\
+              tensorflow/core/ops/state_ops.cc \\
+              tensorflow/core/ops/training_ops.cc \\
+              tensorflow/cc/client/client_session.cc \\
+              tensorflow/cc/framework/gradients.cc \\
+              tensorflow/cc/framework/grad_op_registry.cc \\
+              tensorflow/cc/framework/ops.cc \\
+              tensorflow/cc/framework/scope.cc \\
+              tensorflow/cc/framework/while_gradients.cc \\
+              tensorflow/cc/gradients/array_grad.cc \\
+              tensorflow/cc/gradients/math_grad.cc \\
+              tensorflow/cc/gradients/nn_grad.cc \\
+              tensorflow/cc/ops/const_op.cc \\
+              tensorflow/cc/ops/while_loop.cc \\
+              bazel-genfiles/tensorflow/cc/ops/array_ops.cc \\
+              bazel-genfiles/tensorflow/cc/ops/array_ops_internal.cc \\
+              bazel-genfiles/tensorflow/cc/ops/control_flow_ops.cc \\
+              bazel-genfiles/tensorflow/cc/ops/control_flow_ops_internal.cc \\
+              bazel-genfiles/tensorflow/cc/ops/data_flow_ops.cc \\
+              bazel-genfiles/tensorflow/cc/ops/data_flow_ops_internal.cc \\
+              bazel-genfiles/tensorflow/cc/ops/math_ops.cc \\
+              bazel-genfiles/tensorflow/cc/ops/math_ops_internal.cc \\
+              bazel-genfiles/tensorflow/cc/ops/nn_ops.cc \\
+              bazel-genfiles/tensorflow/cc/ops/nn_ops_internal.cc \\
+              bazel-genfiles/tensorflow/cc/ops/random_ops.cc \\
+              bazel-genfiles/tensorflow/cc/ops/state_ops.cc \\
+              bazel-genfiles/tensorflow/cc/ops/training_ops.cc
+ifeq (\$(BLAS),MKL)
+    TF_CC_SRCS += tensorflow/core/kernels/mkl_aggregate_ops.cc \\
+                  tensorflow/core/kernels/mkl_avgpooling_op.cc \\
+                  tensorflow/core/kernels/mkl_concat_op.cc \\
+                  tensorflow/core/kernels/mkl_conv_ops.cc \\
+                  tensorflow/core/kernels/mkl_cwise_ops_common.cc \\
+                  tensorflow/core/kernels/mkl_fused_batch_norm_op.cc \\
+                  tensorflow/core/kernels/mkl_identity_op.cc \\
+                  tensorflow/core/kernels/mkl_input_conversion_op.cc \\
+                  tensorflow/core/kernels/mkl_relu_op.cc \\
+                  tensorflow/core/kernels/mkl_matmul_op.cc \\
+                  tensorflow/core/kernels/mkl_maxpooling_op.cc \\
+                  tensorflow/core/kernels/mkl_pooling_ops_common.cc \\
+                  tensorflow/core/kernels/mkl_reshape_op.cc \\
+                  tensorflow/core/kernels/mkl_softmax_op.cc \\
+                  tensorflow/core/kernels/mkl_transpose_op.cc
+endif
 PBT_CC_SRCS := \$(shell cat \$(MAKEFILE_DIR)/tf_pb_text_files.txt)
 PROTO_SRCS := \$(shell cat \$(MAKEFILE_DIR)/tf_proto_files.txt)
 BENCHMARK_SRCS := \\
@@ -714,15 +869,23 @@ PROTO_CC_SRCS := \$(addprefix \$(PROTOGENDIR), \$(PROTO_SRCS:.proto=.pb.cc))
 PROTO_OBJS := \$(addprefix \$(OBJDIR), \$(PROTO_SRCS:.proto=.pb.o))
 LIB_OBJS := \$(PROTO_OBJS) \$(TF_CC_OBJS) \$(PBT_OBJS)
 BENCHMARK_OBJS := \$(addprefix \$(OBJDIR), \$(BENCHMARK_SRCS:.cc=.o))
+SUMMARIZE_GRAPH_OBJS := \$(OBJDIR)tensorflow/tools/graph_transforms/file_utils.o \\
+                        \$(OBJDIR)tensorflow/tools/graph_transforms/summarize_graph_main.o \\
+                        \$(OBJDIR)tensorflow/tools/graph_transforms/transform_utils.o
+BENCHMARK_MODEL_OBJS := \$(OBJDIR)tensorflow/core/util/reporter.o \\
+                        \$(OBJDIR)tensorflow/tools/benchmark/benchmark_model.o \\
+                        \$(OBJDIR)tensorflow/tools/benchmark/benchmark_model_main.o
 
 .PHONY: clean cleantarget
 
+SUMMARIZE_GRAPH := \$(BINDIR)summarize_graph
+BENCHMARK_MODEL := \$(BINDIR)benchmark_model
+
 # The target that's compiled if there's no command-line arguments.
-all: \$(LIB_PATH) \$(BENCHMARK_NAME)
+all: \$(LIB_PATH) \$(SUMMARIZE_GRAPH) \$(BENCHMARK_MODEL)
 
 # Rules for target compilation.
 
-
 .phony_version_info:
 tensorflow/core/util/version_info.cc: .phony_version_info
 	tensorflow/tools/git/gen_git_source.sh \$@
@@ -738,6 +901,16 @@ \$(BENCHMARK_NAME): \$(BENCHMARK_OBJS) \$(LIB_PATH) \$(CUDA_LIB_DEPS)
 	-o \$(BENCHMARK_NAME) \$(BENCHMARK_OBJS) \\
 	\$(LIBFLAGS) \$(TEGRA_LIBS) \$(LIB_PATH) \$(LDFLAGS) \$(LIBS) \$(CUDA_LIBS)
 
+\$(SUMMARIZE_GRAPH): \$(SUMMARIZE_GRAPH_OBJS) \$(LIB_PATH)
+	@mkdir -p \$(dir \$@)
+	\$(CXX) \$(CXXFLAGS) \$(INCLUDES) -o \$@ \$(SUMMARIZE_GRAPH_OBJS) \\
+	\$(LIBFLAGS) \$(TEGRA_LIBS) \$(LIB_PATH) \$(LDFLAGS) \$(LIBS) \$(CUDA_LIBS)
+
+\$(BENCHMARK_MODEL): \$(BENCHMARK_MODEL_OBJS) \$(LIB_PATH)
+	@mkdir -p \$(dir \$@)
+	\$(CXX) \$(CXXFLAGS) \$(INCLUDES) -o \$@ \$(BENCHMARK_MODEL_OBJS) \\
+	\$(LIBFLAGS) \$(TEGRA_LIBS) \$(LIB_PATH) \$(LDFLAGS) \$(LIBS) \$(CUDA_LIBS)
+
 # NVCC compilation rules for Tegra
 ifeq (\$(BUILD_FOR_TEGRA),1)
 \$(OBJDIR)%.cu.o: %.cu.cc
diff --git a/tensorflow/core/graph/mkl_layout_pass.cc b/tensorflow/core/graph/mkl_layout_pass.cc
index b966799..5c3d422 100644
--- a/tensorflow/core/graph/mkl_layout_pass.cc
+++ b/tensorflow/core/graph/mkl_layout_pass.cc
@@ -299,8 +299,8 @@ class MklLayoutRewritePass : public GraphOptimizationPass {
     // End - element-wise ops. See note above.
 
     // NOTE: names are alphabetically sorted.
-    rinfo_.push_back({csinfo_.addn, mkl_op_registry::GetMklOpName(csinfo_.addn),
-                      CopyAttrsAddN, AddNRewrite, nullptr});
+    /*rinfo_.push_back({csinfo_.addn, mkl_op_registry::GetMklOpName(csinfo_.addn),
+                      CopyAttrsAddN, AddNRewrite, nullptr});*/
     rinfo_.push_back({csinfo_.add, mkl_op_registry::GetMklOpName(csinfo_.add),
                       CopyAttrsDataType, AlwaysRewrite, nullptr});
     rinfo_.push_back({csinfo_.avg_pool,
@@ -326,9 +326,9 @@ class MklLayoutRewritePass : public GraphOptimizationPass {
     rinfo_.push_back({csinfo_.concatv2,
                       mkl_op_registry::GetMklOpName(csinfo_.concatv2),
                       CopyAttrsConcatV2, AlwaysRewrite, nullptr});
-    rinfo_.push_back({csinfo_.conv2d,
-                      mkl_op_registry::GetMklOpName(csinfo_.conv2d),
-                      CopyAttrsConv2D, AlwaysRewrite, nullptr});
+    //rinfo_.push_back({csinfo_.conv2d,
+    //                  mkl_op_registry::GetMklOpName(csinfo_.conv2d),
+    //                  CopyAttrsConv2D, AlwaysRewrite, nullptr});
     rinfo_.push_back({csinfo_.conv2d_grad_filter,
                       mkl_op_registry::GetMklOpName(csinfo_.conv2d_grad_filter),
                       CopyAttrsConv2D, AlwaysRewrite, nullptr});
@@ -380,8 +380,8 @@ class MklLayoutRewritePass : public GraphOptimizationPass {
     wsinfo_.push_back({csinfo_.max_pool, csinfo_.max_pool_grad, 0, 1, 1, 3});
 
     // Add a rule for merging nodes
-    minfo_.push_back({csinfo_.mkl_conv2d, csinfo_.bias_add, 0,
-                      csinfo_.mkl_conv2d_with_bias});
+    //minfo_.push_back({csinfo_.mkl_conv2d, csinfo_.bias_add, 0,
+    //                  csinfo_.mkl_conv2d_with_bias});
 
     biasaddgrad_matmul_context_ = {csinfo_.bias_add_grad, csinfo_.matmul,
                                    IsBiasAddGradInMatMulContext};
@@ -2451,8 +2451,8 @@ class MklLayoutRewritePass : public GraphOptimizationPass {
     // End - element-wise ops. See note above.
 
     // NOTE: names are alphabetically sorted.
-    rinfo_.push_back({csinfo_.addn, mkl_op_registry::GetMklOpName(csinfo_.addn),
-                      CopyAttrsAddN, AddNRewrite});
+    /*rinfo_.push_back({csinfo_.addn, mkl_op_registry::GetMklOpName(csinfo_.addn),
+                      CopyAttrsAddN, AddNRewrite});*/
     rinfo_.push_back({csinfo_.add, mkl_op_registry::GetMklOpName(csinfo_.add),
                       CopyAttrsDataType, AlwaysRewrite});
     rinfo_.push_back({csinfo_.avg_pool,
@@ -2467,9 +2467,9 @@ class MklLayoutRewritePass : public GraphOptimizationPass {
     rinfo_.push_back({csinfo_.concatv2,
                       mkl_op_registry::GetMklOpName(csinfo_.concatv2),
                       CopyAttrsConcatV2, AlwaysRewrite});
-    rinfo_.push_back({csinfo_.conv2d,
-                      mkl_op_registry::GetMklOpName(csinfo_.conv2d),
-                      CopyAttrsConv2D, AlwaysRewrite});
+    //rinfo_.push_back({csinfo_.conv2d,
+    //                  mkl_op_registry::GetMklOpName(csinfo_.conv2d),
+    //                  CopyAttrsConv2D, AlwaysRewrite});
     rinfo_.push_back({csinfo_.conv2d_with_bias, csinfo_.mkl_conv2d_with_bias,
                       CopyAttrsConv2D, AlwaysRewrite});
     rinfo_.push_back({csinfo_.conv2d_grad_filter,
@@ -2541,8 +2541,8 @@ class MklLayoutRewritePass : public GraphOptimizationPass {
     wsinfo_.push_back({csinfo_.max_pool, csinfo_.max_pool_grad, 0, 1, 1, 3});
 
     // Add a rule for merging nodes
-    minfo_.push_back({csinfo_.conv2d, csinfo_.bias_add,
-                      csinfo_.conv2d_with_bias, GetConv2DOrBiasAdd});
+    //minfo_.push_back({csinfo_.conv2d, csinfo_.bias_add,
+    //                  csinfo_.conv2d_with_bias, GetConv2DOrBiasAdd});
 
     minfo_.push_back({csinfo_.conv2d_grad_filter, csinfo_.bias_add_grad,
                       csinfo_.conv2d_grad_filter_with_bias,
diff --git a/tensorflow/core/grappler/clusters/utils.cc b/tensorflow/core/grappler/clusters/utils.cc
index a751972..39bc657 100644
--- a/tensorflow/core/grappler/clusters/utils.cc
+++ b/tensorflow/core/grappler/clusters/utils.cc
@@ -119,19 +119,6 @@ DeviceProperties GetDeviceInfo(const DeviceNameUtils::ParsedName& device) {
 
   if (device.type == "CPU") {
     return GetLocalCPUInfo();
-  } else if (device.type == "GPU") {
-    if (device.has_id) {
-      TfGpuId tf_gpu_id(device.id);
-      CudaGpuId cuda_gpu_id;
-      Status s = GpuIdManager::TfToCudaGpuId(tf_gpu_id, &cuda_gpu_id);
-      if (!s.ok()) {
-        LOG(ERROR) << s;
-        return unknown;
-      }
-      return GetLocalGPUInfo(cuda_gpu_id);
-    } else {
-      return GetLocalGPUInfo(CudaGpuId(0));
-    }
   }
   return unknown;
 }
diff --git a/tensorflow/core/grappler/costs/utils.cc b/tensorflow/core/grappler/costs/utils.cc
index be54d98..0f3c6f7 100644
--- a/tensorflow/core/grappler/costs/utils.cc
+++ b/tensorflow/core/grappler/costs/utils.cc
@@ -207,16 +207,7 @@ DeviceProperties GetDeviceInfo(const string& device_str) {
 
   DeviceNameUtils::ParsedName parsed;
   if (DeviceNameUtils::ParseFullName(device_str, &parsed)) {
-    if (parsed.type == "GPU") {
-      TfGpuId tf_gpu_id(parsed.id);
-      CudaGpuId cuda_gpu_id;
-      Status s = GpuIdManager::TfToCudaGpuId(tf_gpu_id, &cuda_gpu_id);
-      if (!s.ok()) {
-        // We are probably running simulation without linking cuda libraries.
-        cuda_gpu_id = CudaGpuId(parsed.id);
-      }
-      return GetLocalGPUInfo(cuda_gpu_id);
-    } else if (parsed.type == "CPU") {
+    if (parsed.type == "CPU") {
       return GetLocalCPUInfo();
     }
   }
diff --git a/tensorflow/core/kernels/cwise_op_sigmoid.cc b/tensorflow/core/kernels/cwise_op_sigmoid.cc
index c132fdb..c07ef05 100644
--- a/tensorflow/core/kernels/cwise_op_sigmoid.cc
+++ b/tensorflow/core/kernels/cwise_op_sigmoid.cc
@@ -13,6 +13,7 @@ See the License for the specific language governing permissions and
 limitations under the License.
 ==============================================================================*/
 
+#include "tensorflow/core/framework/register_types.h"
 #include "tensorflow/core/kernels/cwise_ops_common.h"
 #include "tensorflow/core/kernels/cwise_ops_gradients.h"
 
@@ -37,4 +38,51 @@ REGISTER3(SimpleBinaryOp, GPU, "SigmoidGrad", functor::sigmoid_grad, float,
 REGISTER(SimpleBinaryOp, SYCL, "SigmoidGrad", functor::sigmoid_grad, float);
 #endif  // TENSORFLOW_USE_SYCL
 
+template <typename Device, typename T>
+class SigmoidWithCrossEntropyLossOp : public OpKernel {
+ public:
+  explicit SigmoidWithCrossEntropyLossOp(OpKernelConstruction* context)
+      : OpKernel(context) {}
+
+  void Compute(OpKernelContext* context) override {
+    const Tensor& logits_in = context->input(0);
+    const TensorShape shape_in = logits_in.shape();
+    OP_REQUIRES(context, TensorShapeUtils::IsMatrix(shape_in),
+                errors::InvalidArgument("logits must be 2-dimensional"));
+    Tensor* loss_out = nullptr;
+    OP_REQUIRES_OK(context, context->allocate_output(
+            0, TensorShape({shape_in.dim_size(0)}), &loss_out));
+    Tensor* sigmoid_out = nullptr;
+    OP_REQUIRES_OK(context, context->forward_input_or_allocate_output(
+            {0}, 1, shape_in, &sigmoid_out));
+    if (logits_in.NumElements() > 0) {
+      functor::UnaryFunctor<Device, functor::sigmoid<T>> sigmoid_functor;
+      sigmoid_functor(context->eigen_device<Device>(), sigmoid_out->flat<T>(),
+                      logits_in.flat<T>());
+      const auto sigmoid = sigmoid_out->matrix<T>();
+      const auto labels = context->input(1).flat<int>();
+      auto loss = loss_out->vec<T>();
+      for (int i = 0; i < sigmoid_out->dim_size(0); i++) {
+        float xent = 0.f;
+        for (int j = 0; j < sigmoid_out->dim_size(1); j++) {
+          if (j == labels(i)) {
+            xent -= ::logf(sigmoid(i, j));
+          } else {
+            xent -= ::logf(1 - sigmoid(i, j));
+          }
+        }
+        loss(i) == xent;
+      }
+    }
+  }
+};
+
+#undef REGISTER_CPU
+#define REGISTER_CPU(T)                                          \\
+  REGISTER_KERNEL_BUILDER(                                       \\
+      Name("SigmoidWithCrossEntropyLoss").Device(DEVICE_CPU).TypeConstraint<T>("T"), \\
+      SigmoidWithCrossEntropyLossOp<CPUDevice, T>);
+TF_CALL_float(REGISTER_CPU);
+TF_CALL_double(REGISTER_CPU);
+
 }  // namespace tensorflow
diff --git a/tensorflow/core/kernels/neon/depthwiseconv_float.h b/tensorflow/core/kernels/neon/depthwiseconv_float.h
index 11f5be7..fbc13c8 100644
--- a/tensorflow/core/kernels/neon/depthwiseconv_float.h
+++ b/tensorflow/core/kernels/neon/depthwiseconv_float.h
@@ -23,6 +23,23 @@ limitations under the License.
 #include <arm_neon.h>
 #endif
 
+#if defined __GNUC__ && defined __SSE4_1__
+#define USE_NEON
+
+#define OPTIMIZED_OPS_H__IGNORE_DEPRECATED_DECLARATIONS
+#pragma GCC diagnostic push
+#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
+#pragma GCC diagnostic ignored "-Wattributes"
+
+#pragma GCC diagnostic push
+#pragma GCC diagnostic ignored "-Wnarrowing"
+#pragma GCC diagnostic ignored "-Wsequence-point"
+
+#include <NEON_2_SSE.h>
+
+#pragma GCC diagnostic pop
+#endif
+
 namespace tensorflow {
 namespace neon {
 
diff --git a/tensorflow/core/kernels/softmax_op.cc b/tensorflow/core/kernels/softmax_op.cc
index e726089..c350757 100644
--- a/tensorflow/core/kernels/softmax_op.cc
+++ b/tensorflow/core/kernels/softmax_op.cc
@@ -15,6 +15,8 @@ limitations under the License.
 
 // See docs in ../ops/nn_ops.cc.
 
+#include <math.h>
+
 #include "tensorflow/core/lib/strings/str_util.h"
 #define EIGEN_USE_THREADS
 
@@ -23,6 +25,7 @@ limitations under the License.
 #include "tensorflow/core/framework/register_types.h"
 #include "tensorflow/core/framework/tensor.h"
 #include "tensorflow/core/framework/tensor_shape.h"
+#include "tensorflow/core/kernels/cwise_ops.h"
 #include "tensorflow/core/kernels/softmax_op_functor.h"
 
 namespace tensorflow {
@@ -102,4 +105,84 @@ REGISTER_KERNEL_BUILDER(
     Name("Softmax").Device(DEVICE_SYCL).TypeConstraint<double>("T"),
     SoftmaxOp<SYCLDevice, double>);
 #endif  // TENSORFLOW_USE_SYCL
+
+template <typename Device, typename T>
+class SimpleLossGradOp : public OpKernel {
+ public:
+  explicit SimpleLossGradOp(OpKernelConstruction* context) : OpKernel(context) {}
+
+  void Compute(OpKernelContext* context) override {
+    const Tensor& output_in = context->input(0);
+    const TensorShape shape_in = output_in.shape();
+    OP_REQUIRES(context, TensorShapeUtils::IsMatrix(shape_in),
+                errors::InvalidArgument("output must be 2-dimensional"));
+    Tensor* grad_out = nullptr;
+    OP_REQUIRES_OK(context, context->forward_input_or_allocate_output(
+            {0}, 0, shape_in, &grad_out));
+    if (output_in.NumElements() > 0) {
+      const auto output = output_in.matrix<T>();
+      const auto labels = context->input(1).flat<int>();
+      auto grad = grad_out->matrix<T>();
+      for (int r = 0; r < output_in.dim_size(0); r++) {
+          for (int c = 0; c < output_in.dim_size(1); c++) {
+              if (labels(r) == c) {
+                  grad(r, c) = output(r, c) - 1.f;
+              } else {
+                  grad(r, c) = output(r, c);
+              }
+          }
+      }
+    }
+  }
+};
+
+#undef REGISTER_CPU
+#define REGISTER_CPU(T)                                          \\
+  REGISTER_KERNEL_BUILDER(                                       \\
+      Name("SimpleLossGrad").Device(DEVICE_CPU).TypeConstraint<T>("T"), \\
+      SimpleLossGradOp<CPUDevice, T>);
+TF_CALL_float(REGISTER_CPU);
+TF_CALL_double(REGISTER_CPU);
+#undef REGISTER_CPU
+
+template <typename Device, typename T>
+class SoftmaxWithLogLikelihoodLossOp : public OpKernel {
+ public:
+  explicit SoftmaxWithLogLikelihoodLossOp(OpKernelConstruction* context)
+      : OpKernel(context) {}
+
+  void Compute(OpKernelContext* context) override {
+    const Tensor& logits_in = context->input(0);
+    const TensorShape shape_in = logits_in.shape();
+    OP_REQUIRES(context, TensorShapeUtils::IsMatrix(shape_in),
+                errors::InvalidArgument("logits must be 2-dimensional"));
+    Tensor* loss_out = nullptr;
+    OP_REQUIRES_OK(context, context->allocate_output(
+            0, TensorShape({shape_in.dim_size(0)}), &loss_out));
+    Tensor* softmax_out = nullptr;
+    OP_REQUIRES_OK(context, context->forward_input_or_allocate_output(
+            {0}, 1, shape_in, &softmax_out));
+    if (logits_in.NumElements() > 0) {
+      functor::SoftmaxFunctor<Device, T> softmax_functor;
+      auto softmax = softmax_out->matrix<T>();
+      softmax_functor(context->eigen_device<Device>(), logits_in.matrix<T>(),
+                      softmax, false);
+      const auto labels = context->input(1).flat<int>();
+      auto loss = loss_out->vec<T>();
+      typename functor::log<T>::func log_functor;
+      for (int i = 0; i < loss.size(); i++) {
+          loss(i) = -log_functor(softmax(i, labels(i)));
+      }
+    }
+  }
+};
+
+#undef REGISTER_CPU
+#define REGISTER_CPU(T)                                          \\
+  REGISTER_KERNEL_BUILDER(                                       \\
+      Name("SoftmaxWithLogLikelihoodLoss").Device(DEVICE_CPU).TypeConstraint<T>("T"), \\
+      SoftmaxWithLogLikelihoodLossOp<CPUDevice, T>);
+TF_CALL_float(REGISTER_CPU);
+TF_CALL_double(REGISTER_CPU);
+
 }  // namespace tensorflow
diff --git a/tensorflow/core/ops/math_ops.cc b/tensorflow/core/ops/math_ops.cc
index c229bd5..583ea27 100644
--- a/tensorflow/core/ops/math_ops.cc
+++ b/tensorflow/core/ops/math_ops.cc
@@ -258,6 +258,28 @@ expected to create these operators.
 #undef UNARY_REAL
 #undef UNARY_COMPLEX
 
+REGISTER_OP("SigmoidWithCrossEntropyLoss")
+    .Input("logits: T")
+    .Input("labels: int32")
+    .Output("loss: T")
+    .Output("sigmoid: T")
+    .Attr("T: {float, double}")
+    .SetShapeFn([](InferenceContext* c) {
+      ShapeHandle logits;
+      ShapeHandle labels;
+      if (c->WithRank(c->input(0), 2, &logits) == Status::OK() &&
+          c->WithRank(c->input(1), 1, &labels) == Status::OK()) {
+        DimensionHandle batch_size = c->Dim(logits, 0);
+        if (c->Value(batch_size) != c->Value(c->Dim(labels, 0))) {
+            return errors::InvalidArgument("Expect labels of batch size");
+        }
+        c->set_output(0, labels);
+        c->set_output(1, logits);
+        return Status::OK();
+      }
+      return errors::InvalidArgument("Expect logits of rank 2 and labels of rank 1");
+    });
+
 REGISTER_OP("IsNan")
     .Input("x: T")
     .Output("y: bool")
diff --git a/tensorflow/core/ops/nn_ops.cc b/tensorflow/core/ops/nn_ops.cc
index f947d4c..7e36eaa 100644
--- a/tensorflow/core/ops/nn_ops.cc
+++ b/tensorflow/core/ops/nn_ops.cc
@@ -1057,6 +1057,50 @@ REGISTER_OP("LogSoftmax")
 
 // --------------------------------------------------------------------------
 
+REGISTER_OP("SimpleLossGrad")
+    .Input("output: T")
+    .Input("labels: int32")
+    .Output("grad: T")
+    .Attr("T: {float, double}")
+    .SetShapeFn([](InferenceContext* c) {
+      ShapeHandle output;
+      ShapeHandle labels;
+      if (c->WithRank(c->input(0), 2, &output) == Status::OK() &&
+          c->WithRank(c->input(1), 1, &labels) == Status::OK()) {
+        DimensionHandle batch_size = c->Dim(output, 0);
+        if (c->Value(batch_size) != c->Value(c->Dim(labels, 0))) {
+            return errors::InvalidArgument("Expect labels of batch size");
+        }
+        c->set_output(0, output);
+        return Status::OK();
+      }
+      return errors::InvalidArgument("Expect output of rank 2 and labels of rank 1");
+    });
+
+REGISTER_OP("SoftmaxWithLogLikelihoodLoss")
+    .Input("logits: T")
+    .Input("labels: int32")
+    .Output("loss: T")
+    .Output("softmax: T")
+    .Attr("T: {float, double}")
+    .SetShapeFn([](InferenceContext* c) {
+      ShapeHandle logits;
+      ShapeHandle labels;
+      if (c->WithRank(c->input(0), 2, &logits) == Status::OK() &&
+          c->WithRank(c->input(1), 1, &labels) == Status::OK()) {
+        DimensionHandle batch_size = c->Dim(logits, 0);
+        if (c->Value(batch_size) != c->Value(c->Dim(labels, 0))) {
+            return errors::InvalidArgument("Expect labels of batch size");
+        }
+        c->set_output(0, labels);
+        c->set_output(1, logits);
+        return Status::OK();
+      }
+      return errors::InvalidArgument("Expect logits of rank 2 and labels of rank 1");
+    });
+
+// --------------------------------------------------------------------------
+
 REGISTER_OP("SoftmaxCrossEntropyWithLogits")
     .Input("features: T")
     .Input("labels: T")
EOD
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to patch tensorflow!${NC}"
            return 1
        fi
    else
        cd tensorflow
    fi

    # Build tensorflow lite.
    make -j$(nproc) -f tensorflow/contrib/lite/Makefile
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build Tensorflow lite!${NC}"
        return 1
    fi
    sudo mkdir -p $prefix/lib &&
    sudo install tensorflow/contrib/lite/gen/lib/libtensorflow-lite.a $prefix/lib &&
    sudo mkdir -p $prefix/include &&
    install_headers tensorflow/contrib/lite $prefix/include
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install Tensorflow lite!${NC}"
        return 1
    fi

    # Build tensorflow core.
    bazel build //tensorflow/cc:cc_ops
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to generate Tensorflow cc ops files!${NC}"
        return 1
    fi
    make -j$(nproc) -f tensorflow/contrib/makefile/Makefile
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build Tensorflow core!${NC}"
        return 1
    fi
    sudo mkdir -p $prefix/lib &&
    sudo install tensorflow/contrib/makefile/gen/lib/libtensorflow-core.a $prefix/lib &&
    sudo mkdir -p $prefix/include &&
    install_headers tensorflow/cc $prefix/include &&
    install_headers tensorflow/core/framework $prefix/include &&
    install_headers tensorflow/core/graph $prefix/include &&
    install_headers tensorflow/core/lib $prefix/include &&
    install_headers tensorflow/core/platform $prefix/include &&
    install_headers tensorflow/core/public $prefix/include &&
    cd tensorflow/contrib/makefile/gen/proto &&
    install_headers tensorflow/core/framework $prefix/include &&
    install_headers tensorflow/core/lib $prefix/include &&
    install_headers tensorflow/core/protobuf $prefix/include &&
    cd ../../../../../bazel-genfiles &&
    install_headers tensorflow/cc $prefix/include &&
    cd .. &&
    sudo mkdir -p $prefix/include/third_party &&
    sudo cp -a third_party/eigen3 $prefix/include/third_party &&
    sudo mkdir -p $prefix/bin &&
    sudo install tensorflow/contrib/makefile/gen/bin/summarize_graph \
                 tensorflow/contrib/makefile/gen/bin/benchmark_model $prefix/bin
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install Tensorflow core!${NC}"
        return 1
    fi

    cd ..
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
    make -j$(nproc) && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to install x264!${NC}"
        return 1
    fi
    cd ..
}

install_ffmpeg() {
    # Set this variable to empty to use the HEAD.
    ffver=3.4.2
    if [ ! -d "ffmpeg" ] ; then
        git clone --depth=1 git://source.ffmpeg.org/ffmpeg.git -b n$ffver
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download ffmpeg${NC}"
            return 1
        fi
    fi
    cd ffmpeg
    ./configure --enable-gpl --enable-version3 --disable-pic --enable-static --disable-shared \
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
    make -j$(nproc) && sudo make install
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
    make -j $(nproc) && sudo make install
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
    make -j $(nproc) && sudo make install
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
    make -j $(nproc) && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build Google benchmark!${NC}"
        return 1
    fi
    cd ../..
}

install_opencv() {
    ver=3.4.1
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
        export CMAKE_LIBRARY_PATH=${PREFIX}/lib
    fi

    mkdir -p build
    cd build
    cmake -DBUILD_WITH_DEBUG_INFO=ON \
          -DBUILD_DOCS=OFF \
          -DBUILD_IPP_IW=ON \
          -DBUILD_ITT=OFF \
          -DBUILD_FAT_JAVA_LIB=OFF \
          -DBUILD_JASPER=OFF \
          -DBUILD_JPEG=ON \
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
          -DCMAKE_INSTALL_PREFIX=${prefix} \
          -DMKL_ROOT_DIR=${prefix}/intel/mkl \
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
          make -j$(nproc) && sudo make install
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build opencv${NC}"
        return 1
    fi

    cd ../..
}

install_deps &&
install_blas &&
install_eigen &&
install_protobuf &&
install_flatbuffers &&
install_gemmlowp &&
install_nsync &&
install_farmhash &&
install_double_conversion &&
install_neon2sse &&
install_bazel &&
install_tensorflow &&
install_x264 &&
install_ffmpeg &&
install_gflags &&
install_glog &&
install_google_benchmark &&
install_opencv
