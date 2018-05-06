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
version=1.8.0
bazel_version=0.11.1
prefix=/usr/local
mopts="-march=native -mtune=native"

OPTS=`getopt -n 'build.sh' -o b:,m:,p:,v: -l blas:,version:,bazel_version:,prefix:,mopts: -- "$@"`
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
        --bazel_version )           bazel_version="$2" ; shift 2 ;;
        -p | --prefix )             prefix="$2" ; shift 2 ;;
        -m | --mopts )              mopts="$2" ; shift 2 ;;
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
        git libtool unzip wget yasm zlib1g-dev $blas_pkgs &&
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
    prid="12725"
    ver="2018.2.199"
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

install_mkl_dnn() {
    if [ ! -d "mkl-dnn" ] ; then
        git clone --depth=1 https://github.com/intel/mkl-dnn -b v0.13
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
+            set(DEF_ARCH_OPT_FLAGS "${mopts}")
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
        "MKL" ) install_mkl && install_mkl_dnn ;;
        * ) echo -e "${YELLOW}No BLAS will be install.${NC}"
    esac
}

install_eigen() {
    if [ ! -d "eigen" ]; then
        # Tensorflow needs some latest changes.
        # TODO: Switch to release after there is a new one.
        git clone --depth=1 https://github.com/eigenteam/eigen-git-mirror eigen
        rc=$?
        if [ $rc != 0 ]; then
            echo -e "${RED}Failed to download eigen!${NC}"
            return 1
        fi
    fi
    cd eigen
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
        wget https://github.com/bazelbuild/bazel/releases/download/${bazel_version}/bazel_${bazel_version}-linux-x86_64.deb
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
diff --git a/tensorflow/contrib/lite/Makefile b/tensorflow/contrib/lite/Makefile
index b4504f2..1cb663e 100644
--- a/tensorflow/contrib/lite/Makefile
+++ b/tensorflow/contrib/lite/Makefile
@@ -1,3 +1,4 @@
+SHELL := /bin/bash
 
 # Find where we're running from, so we can store generated files here.
 ifeq (\$(origin MAKEFILE_DIR), undefined)
@@ -28,32 +29,16 @@ GENDIR := \$(MAKEFILE_DIR)/gen/obj/
 
 # Settings for the host compiler.
 CXX := \$(CC_PREFIX)gcc
-CXXFLAGS := --std=c++11 -O3 -DNDEBUG
+CXXFLAGS := --std=c++11 -O3 -DNDEBUG ${mopts} -DEIGEN_DONT_PARALLELIZE
 CC := \$(CC_PREFIX)gcc
-CFLAGS := -O3 -DNDEBUG
+CFLAGS := -O3 -DNDEBUG ${mopts}
 LDOPTS :=
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
-LIBS := \\
--lstdc++ \\
--lpthread \\
--lm \\
--lz
+INCLUDES := -I. -I\$(MAKEFILE_DIR)/../../../ -I${prefix}/include -I${prefix}/include/eigen3 -I${prefix}/include/gemmlowp
+
+LIBS := -lfarmhash -lstdc++ -lpthread -lm -lz
 
 # If we're on Linux, also link in the dl library.
 ifeq (\$(HOST_OS),LINUX)
@@ -98,7 +83,8 @@ \$(wildcard tensorflow/contrib/lite/*test.cc) \\
 \$(wildcard tensorflow/contrib/lite/*/*test.cc) \\
 \$(wildcard tensorflow/contrib/lite/*/*/*test.cc) \\
 \$(wildcard tensorflow/contrib/lite/*/*/*/*test.cc) \\
-\$(wildcard tensorflow/contrib/lite/kernels/test_util.cc) \\
+tensorflow/contrib/lite/kernels/internal/spectrogram.cc \\
+tensorflow/contrib/lite/kernels/test_util.cc \\
 \$(BENCHMARK_SRCS)
 # Filter out all the excluded files.
 TF_LITE_CC_SRCS := \$(filter-out \$(CORE_CC_EXCLUDE_SRCS), \$(CORE_CC_ALL_SRCS))
@@ -118,7 +104,7 @@ \$(OBJDIR)%.o: %.c
 	\$(CC) \$(CCFLAGS) \$(INCLUDES) -c \$< -o \$@
 
 # The target that's compiled if there's no command-line arguments.
-all: \$(LIB_PATH) \$(BENCHMARK_PATH)
+all: \$(LIB_PATH)
 
 # Gathers together all the objects we've compiled into a single '.a' archive.
 \$(LIB_PATH): \$(LIB_OBJS)
diff --git a/tensorflow/contrib/lite/Makefile.orig b/tensorflow/contrib/lite/Makefile.orig
new file mode 100644
index 0000000..b4504f2
--- /dev/null
+++ b/tensorflow/contrib/lite/Makefile.orig
@@ -0,0 +1,148 @@
+
+# Find where we're running from, so we can store generated files here.
+ifeq (\$(origin MAKEFILE_DIR), undefined)
+	MAKEFILE_DIR := \$(shell dirname \$(realpath \$(lastword \$(MAKEFILE_LIST))))
+endif
+
+# Try to figure out the host system
+HOST_OS :=
+ifeq (\$(OS),Windows_NT)
+	HOST_OS = WINDOWS
+else
+	UNAME_S := \$(shell uname -s)
+	ifeq (\$(UNAME_S),Linux)
+	        HOST_OS := LINUX
+	endif
+	ifeq (\$(UNAME_S),Darwin)
+		HOST_OS := OSX
+	endif
+endif
+
+ARCH := \$(shell if [[ \$(shell uname -m) =~ i[345678]86 ]]; then echo x86_32; else echo \$(shell uname -m); fi)
+
+# Where compiled objects are stored.
+OBJDIR := \$(MAKEFILE_DIR)/gen/obj/
+BINDIR := \$(MAKEFILE_DIR)/gen/bin/
+LIBDIR := \$(MAKEFILE_DIR)/gen/lib/
+GENDIR := \$(MAKEFILE_DIR)/gen/obj/
+
+# Settings for the host compiler.
+CXX := \$(CC_PREFIX)gcc
+CXXFLAGS := --std=c++11 -O3 -DNDEBUG
+CC := \$(CC_PREFIX)gcc
+CFLAGS := -O3 -DNDEBUG
+LDOPTS :=
+LDOPTS += -L${prefix}/lib
+ARFLAGS := -r
+
+INCLUDES := \\
+-I. \\
+-I\$(MAKEFILE_DIR)/../../../ \\
+-I\$(MAKEFILE_DIR)/downloads/ \\
+-I\$(MAKEFILE_DIR)/downloads/eigen \\
+-I\$(MAKEFILE_DIR)/downloads/gemmlowp \\
+-I\$(MAKEFILE_DIR)/downloads/neon_2_sse \\
+-I\$(MAKEFILE_DIR)/downloads/farmhash/src \\
+-I\$(MAKEFILE_DIR)/downloads/flatbuffers/include \\
+-I\$(GENDIR)
+# This is at the end so any globally-installed frameworks like protobuf don't
+# override local versions in the source tree.
+INCLUDES += -I${prefix}/include
+
+LIBS := \\
+-lstdc++ \\
+-lpthread \\
+-lm \\
+-lz
+
+# If we're on Linux, also link in the dl library.
+ifeq (\$(HOST_OS),LINUX)
+	LIBS += -ldl
+endif
+
+include \$(MAKEFILE_DIR)/ios_makefile.inc
+include \$(MAKEFILE_DIR)/rpi_makefile.inc
+
+# This library is the main target for this makefile. It will contain a minimal
+# runtime that can be linked in to other programs.
+LIB_NAME := libtensorflow-lite.a
+LIB_PATH := \$(LIBDIR)\$(LIB_NAME)
+
+# A small example program that shows how to link against the library.
+BENCHMARK_PATH := \$(BINDIR)benchmark_model
+
+BENCHMARK_SRCS := \\
+tensorflow/contrib/lite/tools/benchmark_model.cc
+BENCHMARK_OBJS := \$(addprefix \$(OBJDIR), \\
+\$(patsubst %.cc,%.o,\$(patsubst %.c,%.o,\$(BENCHMARK_SRCS))))
+
+# What sources we want to compile, must be kept in sync with the main Bazel
+# build files.
+
+CORE_CC_ALL_SRCS := \\
+\$(wildcard tensorflow/contrib/lite/*.cc) \\
+\$(wildcard tensorflow/contrib/lite/kernels/*.cc) \\
+\$(wildcard tensorflow/contrib/lite/kernels/internal/*.cc) \\
+\$(wildcard tensorflow/contrib/lite/kernels/internal/optimized/*.cc) \\
+\$(wildcard tensorflow/contrib/lite/kernels/internal/reference/*.cc) \\
+\$(wildcard tensorflow/contrib/lite/*.c) \\
+\$(wildcard tensorflow/contrib/lite/kernels/*.c) \\
+\$(wildcard tensorflow/contrib/lite/kernels/internal/*.c) \\
+\$(wildcard tensorflow/contrib/lite/kernels/internal/optimized/*.c) \\
+\$(wildcard tensorflow/contrib/lite/kernels/internal/reference/*.c) \\
+\$(wildcard tensorflow/contrib/lite/downloads/farmhash/src/farmhash.cc)
+# Remove any duplicates.
+CORE_CC_ALL_SRCS := \$(sort \$(CORE_CC_ALL_SRCS))
+CORE_CC_EXCLUDE_SRCS := \\
+\$(wildcard tensorflow/contrib/lite/*test.cc) \\
+\$(wildcard tensorflow/contrib/lite/*/*test.cc) \\
+\$(wildcard tensorflow/contrib/lite/*/*/*test.cc) \\
+\$(wildcard tensorflow/contrib/lite/*/*/*/*test.cc) \\
+\$(wildcard tensorflow/contrib/lite/kernels/test_util.cc) \\
+\$(BENCHMARK_SRCS)
+# Filter out all the excluded files.
+TF_LITE_CC_SRCS := \$(filter-out \$(CORE_CC_EXCLUDE_SRCS), \$(CORE_CC_ALL_SRCS))
+# File names of the intermediate files target compilation generates.
+TF_LITE_CC_OBJS := \$(addprefix \$(OBJDIR), \\
+\$(patsubst %.cc,%.o,\$(patsubst %.c,%.o,\$(TF_LITE_CC_SRCS))))
+LIB_OBJS := \$(TF_LITE_CC_OBJS)
+
+# For normal manually-created TensorFlow C++ source files.
+\$(OBJDIR)%.o: %.cc
+	@mkdir -p \$(dir \$@)
+	\$(CXX) \$(CXXFLAGS) \$(INCLUDES) -c \$< -o \$@
+
+# For normal manually-created TensorFlow C++ source files.
+\$(OBJDIR)%.o: %.c
+	@mkdir -p \$(dir \$@)
+	\$(CC) \$(CCFLAGS) \$(INCLUDES) -c \$< -o \$@
+
+# The target that's compiled if there's no command-line arguments.
+all: \$(LIB_PATH) \$(BENCHMARK_PATH)
+
+# Gathers together all the objects we've compiled into a single '.a' archive.
+\$(LIB_PATH): \$(LIB_OBJS)
+	@mkdir -p \$(dir \$@)
+	\$(AR) \$(ARFLAGS) \$(LIB_PATH) \$(LIB_OBJS)
+
+\$(BENCHMARK_PATH): \$(BENCHMARK_OBJS) \$(LIB_PATH)
+	@mkdir -p \$(dir \$@)
+	\$(CXX) \$(CXXFLAGS) \$(INCLUDES) \\
+	-o \$(BENCHMARK_PATH) \$(BENCHMARK_OBJS) \\
+	\$(LIBFLAGS) \$(LIB_PATH) \$(LDFLAGS) \$(LIBS)
+
+# Gets rid of all generated files.
+clean:
+	rm -rf \$(MAKEFILE_DIR)/gen
+
+# Gets rid of target files only, leaving the host alone. Also leaves the lib
+# directory untouched deliberately, so we can persist multiple architectures
+# across builds for iOS and Android.
+cleantarget:
+	rm -rf \$(OBJDIR)
+	rm -rf \$(BINDIR)
+
+\$(DEPDIR)/%.d: ;
+.PRECIOUS: \$(DEPDIR)/%.d
+
+-include \$(patsubst %,\$(DEPDIR)/%.d,\$(basename \$(TF_CC_SRCS)))
diff --git a/tensorflow/contrib/lite/interpreter.cc b/tensorflow/contrib/lite/interpreter.cc
index 4575fe8..4b8bcbc 100644
--- a/tensorflow/contrib/lite/interpreter.cc
+++ b/tensorflow/contrib/lite/interpreter.cc
@@ -18,6 +18,7 @@ limitations under the License.
 #include <cstdarg>
 #include <cstdint>
 #include <cstring>
+#include <Eigen/Core>
 #include "tensorflow/contrib/lite/arena_planner.h"
 #include "tensorflow/contrib/lite/context.h"
 #include "tensorflow/contrib/lite/error_reporter.h"
diff --git a/tensorflow/contrib/lite/kernels/register.cc b/tensorflow/contrib/lite/kernels/register.cc
index 0f98154..03f68ae 100644
--- a/tensorflow/contrib/lite/kernels/register.cc
+++ b/tensorflow/contrib/lite/kernels/register.cc
@@ -139,8 +139,6 @@ BuiltinOpResolver::BuiltinOpResolver() {
   // TODO(andrewharp, ahentz): Move these somewhere more appropriate so that
   // custom ops aren't always included by default.
   AddCustom("Mfcc", tflite::ops::custom::Register_MFCC());
-  AddCustom("AudioSpectrogram",
-            tflite::ops::custom::Register_AUDIO_SPECTROGRAM());
 }
 
 TfLiteRegistration* BuiltinOpResolver::FindOp(
diff --git a/tensorflow/contrib/lite/nnapi/NeuralNetworksShim.h b/tensorflow/contrib/lite/nnapi/NeuralNetworksShim.h
index 85aca36..d4754b9 100644
--- a/tensorflow/contrib/lite/nnapi/NeuralNetworksShim.h
+++ b/tensorflow/contrib/lite/nnapi/NeuralNetworksShim.h
@@ -58,8 +58,12 @@ inline void* loadFunction(const char* name) {
 }
 
 inline bool NNAPIExists() {
+#ifdef __ANDROID__
   static bool nnapi_is_available = getLibraryHandle();
   return nnapi_is_available;
+#else
+  return false;
+#endif
 }
 
 // nn api types
diff --git a/tensorflow/contrib/makefile/Makefile b/tensorflow/contrib/makefile/Makefile
index 05e8d90..810c1ac 100644
--- a/tensorflow/contrib/makefile/Makefile
+++ b/tensorflow/contrib/makefile/Makefile
@@ -81,15 +81,7 @@ ifeq (\$(HAS_GEN_HOST_PROTOC),true)
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
--I\$(HOST_GENDIR)
+HOST_INCLUDES := -I. -I\$(MAKEFILE_DIR)/../../.. -I\$(HOST_GENDIR) -I${prefix}/include/eigen3 -I${prefix}/include/gemmlowp
 ifeq (\$(HAS_GEN_HOST_PROTOC),true)
 	HOST_INCLUDES += -I\$(MAKEFILE_DIR)/gen/protobuf-host/include
 endif
@@ -97,13 +89,7 @@ endif
 # override local versions in the source tree.
 HOST_INCLUDES += -I/usr/local/include
 
-HOST_LIBS := \\
-\$(HOST_NSYNC_LIB) \\
--lstdc++ \\
--lprotobuf \\
--lpthread \\
--lm \\
--lz
+HOST_LIBS := -lnsync -lstdc++ -lprotobuf -lpthread -lm -lz
 
 # If we're on Linux, also link in the dl library.
 ifeq (\$(HOST_OS),LINUX)
@@ -151,28 +137,29 @@ PROTOGENDIR := \$(GENDIR)proto/
 DEPDIR := \$(GENDIR)dep/
 \$(shell mkdir -p \$(DEPDIR) >/dev/null)
 
+BLAS?=MKL
+BLAS_CXX_FLAGS/ATLAS:=-DEIGEN_USE_BLAS -DEIGEN_USE_LAPACKE
+BLAS_CXX_FLAGS/OpenBLAS:=-DEIGEN_USE_BLAS -DEIGEN_USE_LAPACKE
+BLAS_CXX_FLAGS/MKL:=-DINTEL_MKL -DINTEL_MKL_ML -DEIGEN_USE_MKL_ALL -DMKL_DIRECT_CALL -I${prefix}/intel/mkl/include -I${prefix}/intel/mkldnn/include
+BLAS_LD_FLAGS/ATLAS:=-L${prefix}/ATLAS/lib -llapack -lcblas -lf77blas -latlas -lgfortran -lquadmath
+BLAS_LD_FLAGS/OpenBLAS:=-L${prefix}/OpenBLAS/lib -lopenblas -lgfortran -lquadmath
+# See https://software.intel.com/en-us/articles/intel-mkl-link-line-advisor/
+BLAS_LD_FLAGS/MKL:=-L${prefix}/intel/mkl/lib -L${prefix}/intel/mkldnn/lib/ -lmkldnn \\
+	-Wl,--start-group -lmkl_intel_lp64 -lmkl_sequential -lmkl_core -Wl,--end-group
+
 # Settings for the target compiler.
 CXX := \$(CC_PREFIX) gcc
-OPTFLAGS := -O2
+OPTFLAGS := -O3 \$(BLAS_CXX_FLAGS/\$(BLAS)) -DEIGEN_DONT_PARALLELIZE
 
 ifneq (\$(TARGET),ANDROID)
-   OPTFLAGS += -march=native
+   OPTFLAGS += ${mopts}
 endif
 
-CXXFLAGS := --std=c++11 -DIS_SLIM_BUILD -fno-exceptions -DNDEBUG \$(OPTFLAGS)
-LDFLAGS := \\
--L/usr/local/lib
+CXXFLAGS := --std=c++11 -DIS_SLIM_BUILD -DNDEBUG \$(OPTFLAGS)
+LDFLAGS := -L${prefix}/lib
 DEPFLAGS = -MT \$@ -MMD -MP -MF \$(DEPDIR)/\$*.Td
 
-INCLUDES := \\
--I. \\
--I\$(MAKEFILE_DIR)/downloads/ \\
--I\$(MAKEFILE_DIR)/downloads/eigen \\
--I\$(MAKEFILE_DIR)/downloads/gemmlowp \\
--I\$(MAKEFILE_DIR)/downloads/nsync/public \\
--I\$(MAKEFILE_DIR)/downloads/fft2d \\
--I\$(PROTOGENDIR) \\
--I\$(PBTGENDIR)
+INCLUDES := -I. -I\$(PROTOGENDIR) -I\$(PBTGENDIR) -I${prefix}/include/eigen3 -I${prefix}/include/gemmlowp
 ifeq (\$(HAS_GEN_HOST_PROTOC),true)
 	INCLUDES += -I\$(MAKEFILE_DIR)/gen/protobuf-host/include
 endif
@@ -180,12 +167,7 @@ endif
 # override local versions in the source tree.
 INCLUDES += -I/usr/local/include
 
-LIBS := \\
-\$(TARGET_NSYNC_LIB) \\
--lstdc++ \\
--lprotobuf \\
--lz \\
--lm
+LIBS := \$(BLAS_LD_FLAGS/\$(BLAS)) -lnsync -lstdc++ -lprotobuf -lz -lm
 
 ifeq (\$(HAS_GEN_HOST_PROTOC),true)
 	PROTOC := \$(MAKEFILE_DIR)/gen/protobuf-host/bin/protoc
@@ -215,7 +197,6 @@ ifeq (\$(HAS_GEN_HOST_PROTOC),true)
 	LIBFLAGS += -L\$(MAKEFILE_DIR)/gen/protobuf-host/lib
 	export LD_LIBRARY_PATH=\$(MAKEFILE_DIR)/gen/protobuf-host/lib
 endif
-	CXXFLAGS += -fPIC
 	LIBFLAGS += -Wl,--allow-multiple-definition -Wl,--whole-archive
 	LDFLAGS := -Wl,--no-whole-archive
 endif
@@ -331,7 +312,7 @@ \$(MARCH_OPTION) \\
 -I\$(PBTGENDIR)
 
 	LIBS := \\
-\$(TARGET_NSYNC_LIB) \\
+-lnsync \\
 -lgnustl_static \\
 -lprotobuf \\
 -llog \\
@@ -676,10 +657,144 @@ endif  # TEGRA
 # Filter out all the excluded files.
 TF_CC_SRCS := \$(filter-out \$(CORE_CC_EXCLUDE_SRCS), \$(CORE_CC_ALL_SRCS))
 # Add in any extra files that don't fit the patterns easily
-TF_CC_SRCS += tensorflow/contrib/makefile/downloads/fft2d/fftsg.c
-TF_CC_SRCS += tensorflow/core/common_runtime/gpu/gpu_id_manager.cc
 # Also include the op and kernel definitions.
-TF_CC_SRCS += \$(shell cat \$(MAKEFILE_DIR)/tf_op_files.txt)
+TF_CC_SRCS += tensorflow/core/kernels/avgpooling_op.cc \\
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
+              tensorflow/core/kernels/cwise_op_reciprocal.cc \\
+              tensorflow/core/kernels/cwise_op_round.cc \\
+              tensorflow/core/kernels/cwise_op_rsqrt.cc \\
+              tensorflow/core/kernels/cwise_op_sigmoid.cc \\
+              tensorflow/core/kernels/cwise_op_sqrt.cc \\
+              tensorflow/core/kernels/cwise_op_sub.cc \\
+              tensorflow/core/kernels/control_flow_ops.cc \\
+              tensorflow/core/kernels/deep_conv2d.cc \\
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
+              tensorflow/core/kernels/ops_util.cc \\
+              tensorflow/core/kernels/pack_op.cc \\
+              tensorflow/core/kernels/pad_op.cc \\
+              tensorflow/core/kernels/pooling_ops_common.cc \\
+              tensorflow/core/kernels/quantized_bias_add_op.cc \\
+              tensorflow/core/kernels/quantization_utils.cc \\
+              tensorflow/core/kernels/reduction_ops_all.cc \\
+              tensorflow/core/kernels/reduction_ops_common.cc \\
+              tensorflow/core/kernels/reduction_ops_max.cc \\
+              tensorflow/core/kernels/reduction_ops_mean.cc \\
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
+              tensorflow/core/kernels/transpose_functor_cpu.cc \\
+              tensorflow/core/kernels/transpose_op.cc \\
+              tensorflow/core/kernels/unpack_op.cc \\
+              tensorflow/core/kernels/where_op.cc \\
+              tensorflow/core/ops/array_ops.cc \\
+              tensorflow/core/ops/control_flow_ops.cc \\
+              tensorflow/core/ops/data_flow_ops.cc \\
+              tensorflow/core/ops/function_ops.cc \\
+              tensorflow/core/ops/functional_ops.cc \\
+              tensorflow/core/ops/image_ops.cc \\
+              tensorflow/core/ops/logging_ops.cc \\
+              tensorflow/core/ops/math_ops.cc \\
+              tensorflow/core/ops/nn_ops.cc \\
+              tensorflow/core/ops/no_op.cc
+ifeq (\$(BLAS),MKL)
+	TF_CC_SRCS += tensorflow/core/kernels/mkl_avgpooling_op.cc \\
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
@@ -708,15 +823,23 @@ PROTO_CC_SRCS := \$(addprefix \$(PROTOGENDIR), \$(PROTO_SRCS:.proto=.pb.cc))
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
@@ -732,6 +855,16 @@ \$(BENCHMARK_NAME): \$(BENCHMARK_OBJS) \$(LIB_PATH) \$(CUDA_LIB_DEPS)
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
diff --git a/tensorflow/core/common_runtime/process_util.cc b/tensorflow/core/common_runtime/process_util.cc
index 7ff360e..f8c9c69 100644
--- a/tensorflow/core/common_runtime/process_util.cc
+++ b/tensorflow/core/common_runtime/process_util.cc
@@ -15,9 +15,6 @@ limitations under the License.
 
 #include "tensorflow/core/common_runtime/process_util.h"
 
-#ifdef INTEL_MKL
-#include <omp.h>
-#endif
 #include <string.h>
 
 #include "tensorflow/core/lib/core/threadpool.h"
@@ -52,22 +49,8 @@ thread::ThreadPool* ComputePool(const SessionOptions& options) {
 int32 NumInterOpThreadsFromSessionOptions(const SessionOptions& options) {
   const int32 inter_op = options.config.inter_op_parallelism_threads();
   if (inter_op != 0) return inter_op;
-#ifdef INTEL_MKL
-  // MKL library executes ops in parallel using OMP threads
-  // Set inter_op conservatively to avoid thread oversubscription that could 
-  // lead to severe perf degradations and OMP resource exhaustion
-  const int mkl_intra_op = omp_get_max_threads();
-  CHECK_GE(mkl_intra_op, 1);
-  const int32 mkl_inter_op = std::max(
-          (port::NumSchedulableCPUs() + mkl_intra_op - 1) / mkl_intra_op, 2);
-  VLOG(0) << "Creating new thread pool with default inter op setting: "
-          << mkl_inter_op
-          << ". Tune using inter_op_parallelism_threads for best performance.";
-  return mkl_inter_op;
-#else
   // Default to using the number of cores available in the process.
   return port::NumSchedulableCPUs();
-#endif
 }
 
 thread::ThreadPool* NewThreadPoolFromSessionOptions(
diff --git a/tensorflow/core/grappler/clusters/utils.cc b/tensorflow/core/grappler/clusters/utils.cc
index 50d6e64..ec5698a 100644
--- a/tensorflow/core/grappler/clusters/utils.cc
+++ b/tensorflow/core/grappler/clusters/utils.cc
@@ -118,19 +118,6 @@ DeviceProperties GetDeviceInfo(const DeviceNameUtils::ParsedName& device) {
 
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
index f318e39..586cdc8 100644
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
    make -j$(nproc) -f tensorflow/contrib/makefile/Makefile
    rc=$?
    if [ $rc != 0 ]; then
        echo -e "${RED}Failed to build Tensorflow core!${NC}"
        return 1
    fi
    sudo mkdir -p $prefix/lib &&
    sudo install tensorflow/contrib/makefile/gen/lib/libtensorflow-core.a $prefix/lib &&
    sudo mkdir -p $prefix/include &&
    install_headers tensorflow/core/framework $prefix/include &&
    install_headers tensorflow/core/lib $prefix/include &&
    install_headers tensorflow/core/platform $prefix/include &&
    install_headers tensorflow/core/public $prefix/include &&
    cd tensorflow/contrib/makefile/gen/proto &&
    install_headers tensorflow/core/framework $prefix/include &&
    install_headers tensorflow/core/lib $prefix/include &&
    install_headers tensorflow/core/protobuf $prefix/include &&
    cd ../../../../.. &&
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
install_neon2sse &&
install_tensorflow &&
install_x264 &&
install_ffmpeg &&
install_gflags &&
install_glog &&
install_google_benchmark &&
install_opencv
