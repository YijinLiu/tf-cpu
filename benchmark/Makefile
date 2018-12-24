.SECONDARY:

SHELL:=/bin/bash
PROJECT_ROOT:=$(shell readlink -f $(dir $(lastword $(MAKEFILE_LIST)))/..)
SRC:=$(PROJECT_ROOT)/benchmark
BIN:=$(PROJECT_ROOT)/benchmark/bin
TESTDATA:=$(PROJECT_ROOT)/benchmark/testdata

all: run_classify_lite run_obj_detect_lite run_classify run_obj_detect

run_classify_lite: $(BIN)/classify_lite \
                   $(TESTDATA)/mobilenet_v1_1.0_224_quant.tflite \
                   $(TESTDATA)/mobilenet_v1_1.0_192_quant.tflite \
                   $(TESTDATA)/mobilenet_v1_1.0_160_quant.tflite \
                   $(TESTDATA)/mobilenet_v1_1.0_128_quant.tflite \
                   $(TESTDATA)/mobilenet_v1_0.75_128_quant.tflite \
                   $(TESTDATA)/mobilenet_v1_0.75_160_quant.tflite \
                   $(TESTDATA)/mobilenet_v1_0.75_192_quant.tflite \
                   $(TESTDATA)/mobilenet_v1_0.75_224_quant.tflite \
                   $(TESTDATA)/mobilenet_v1_1.0_224.tflite \
                   $(TESTDATA)/mobilenet_v1_1.0_192.tflite \
                   $(TESTDATA)/mobilenet_v1_1.0_160.tflite \
                   $(TESTDATA)/mobilenet_v1_1.0_128.tflite \
                   $(TESTDATA)/mobilenet_v1_0.75_128.tflite \
                   $(TESTDATA)/mobilenet_v1_0.75_160.tflite \
                   $(TESTDATA)/mobilenet_v1_0.75_192.tflite \
                   $(TESTDATA)/mobilenet_v1_0.75_224.tflite \
                   $(TESTDATA)/mobilenet_v2_1.4_224.tflite \
                   $(TESTDATA)/mobilenet_v2_1.3_224.tflite \
                   $(TESTDATA)/mobilenet_v2_1.0_224.tflite \
                   $(TESTDATA)/mobilenet_v2_1.0_192.tflite \
                   $(TESTDATA)/mobilenet_v2_1.0_160.tflite \
                   $(TESTDATA)/mobilenet_v2_1.0_128.tflite \
                   $(TESTDATA)/mobilenet_v2_1.0_96.tflite \
                   $(TESTDATA)/mobilenet_v2_0.75_224.tflite \
                   $(TESTDATA)/mobilenet_v2_0.75_192.tflite \
                   $(TESTDATA)/mobilenet_v2_0.75_160.tflite \
                   $(TESTDATA)/mobilenet_v2_0.75_128.tflite \
                   $(TESTDATA)/mobilenet_v2_0.75_96.tflite \
                   $(TESTDATA)/mobilenet_labels.txt
	$(BIN)/classify_lite

run_obj_detect_lite: $(BIN)/obj_detect_lite
	@echo -e "\e[0;92mRunning ssdlite_mobilenet_v2_coco10_lite ...\e[0m"
	$(BIN)/obj_detect_lite \
	    --image_file=$(TESTDATA)/dogs.jpeg --output=dogs.ssdlite_mobilenet_v2_coco10_lite.jpeg \
	    --model_file=$(PROJECT_ROOT)/models/objdetect/coco10.tflite \
	    --labels_file=$(PROJECT_ROOT)/models/objdetect/coco10_labels.txt
	$(BIN)/obj_detect_lite \
	    --image_file=$(TESTDATA)/beach.jpeg --output=beach.ssdlite_mobilenet_v2_coco10_lite.jpeg \
	    --model_file=$(PROJECT_ROOT)/models/objdetect/coco10.tflite \
	    --labels_file=$(PROJECT_ROOT)/models/objdetect/coco10_labels.txt
	$(BIN)/obj_detect_lite \
	    --video_file=$(TESTDATA)/beach.mkv --output=beach.ssdlite_mobilenet_v2_coco10_lite.mkv \
	    --model_file=$(PROJECT_ROOT)/models/objdetect/coco10.tflite \
	    --labels_file=$(PROJECT_ROOT)/models/objdetect/coco10_labels.txt

TF_VLOG_LEVEL?=-1

run_classify: $(BIN)/classify \
              $(TESTDATA)/mobilenet_v1_1.0_224_quant_frozen.pb \
              $(TESTDATA)/mobilenet_v1_1.0_192_quant_frozen.pb \
              $(TESTDATA)/mobilenet_v1_1.0_160_quant_frozen.pb \
              $(TESTDATA)/mobilenet_v1_1.0_128_quant_frozen.pb \
              $(TESTDATA)/mobilenet_v1_0.75_128_quant_frozen.pb \
              $(TESTDATA)/mobilenet_v1_0.75_160_quant_frozen.pb \
              $(TESTDATA)/mobilenet_v1_0.75_192_quant_frozen.pb \
              $(TESTDATA)/mobilenet_v1_0.75_224_quant_frozen.pb \
              $(TESTDATA)/mobilenet_v1_1.0_224_frozen.pb \
              $(TESTDATA)/mobilenet_v1_1.0_192_frozen.pb \
              $(TESTDATA)/mobilenet_v1_1.0_160_frozen.pb \
              $(TESTDATA)/mobilenet_v1_1.0_128_frozen.pb \
              $(TESTDATA)/mobilenet_v1_0.75_128_frozen.pb \
              $(TESTDATA)/mobilenet_v1_0.75_160_frozen.pb \
              $(TESTDATA)/mobilenet_v1_0.75_192_frozen.pb \
              $(TESTDATA)/mobilenet_v1_0.75_224_frozen.pb \
              $(TESTDATA)/mobilenet_v2_1.4_224_frozen.pb \
              $(TESTDATA)/mobilenet_v2_1.3_224_frozen.pb \
              $(TESTDATA)/mobilenet_v2_1.0_224_frozen.pb \
              $(TESTDATA)/mobilenet_v2_1.0_192_frozen.pb \
              $(TESTDATA)/mobilenet_v2_1.0_160_frozen.pb \
              $(TESTDATA)/mobilenet_v2_1.0_128_frozen.pb \
              $(TESTDATA)/mobilenet_v2_1.0_96_frozen.pb \
              $(TESTDATA)/mobilenet_v2_0.75_224_frozen.pb \
              $(TESTDATA)/mobilenet_v2_0.75_192_frozen.pb \
              $(TESTDATA)/mobilenet_v2_0.75_160_frozen.pb \
              $(TESTDATA)/mobilenet_v2_0.75_128_frozen.pb \
              $(TESTDATA)/mobilenet_v2_0.75_96_frozen.pb \
              $(TESTDATA)/mobilenet_labels.txt
	TF_CPP_MIN_VLOG_LEVEL=$(TF_VLOG_LEVEL) $(BIN)/classify

run_obj_detect: run_obj_detect_ssd_mobilenet_v1_coco_2017_11_17 \
                run_obj_detect_ssd_mobilenet_v2_coco_2018_03_29 \
                run_obj_detect_ssdlite_mobilenet_v2_coco_2018_05_09 \
                run_obj_detect_ssd_mobilenet_v1_fpn_shared_box_predictor_640x640_coco14_sync_2018_07_03 \
                run_obj_detect_ssdlite_mobilenet_v2_coco10

OBJ_DETECT_LABELS_TXT/ssd_mobilenet_v1_coco_2017_11_17=coco_labels.txt
OBJ_DETECT_LABELS_TXT/ssd_mobilenet_v2_coco_2018_03_29=coco_labels.txt
OBJ_DETECT_LABELS_TXT/ssdlite_mobilenet_v2_coco_2018_05_09=coco_labels.txt
OBJ_DETECT_LABELS_TXT/ssd_mobilenet_v1_fpn_shared_box_predictor_640x640_coco14_sync_2018_07_03=coco_labels.txt
OBJ_DETECT_LABELS_TXT/ssdlite_mobilenet_v2_coco10=coco10_labels.txt

run_obj_detect_%: $(TESTDATA)/%_frozen.pb $(BIN)/obj_detect
	@echo -e "\e[0;92mRunning $* ...\e[0m"
	@mkdir -p $*
	TF_CPP_MIN_VLOG_LEVEL=$(TF_VLOG_LEVEL) $(BIN)/obj_detect \
	    --image_files=$(TESTDATA)/dogs.jpeg,$(TESTDATA)/beach.jpeg,$(TESTDATA)/baby.jpeg --output_dir=$* \
	    --model_file=$< --labels_file=$(PROJECT_ROOT)/models/objdetect/$(OBJ_DETECT_LABELS_TXT/$*)
	TF_CPP_MIN_VLOG_LEVEL=$(TF_VLOG_LEVEL) $(BIN)/obj_detect \
	    --video_file=$(TESTDATA)/beach.mkv --output_dir=$* \
	    --model_file=$< --labels_file=$(PROJECT_ROOT)/models/objdetect/$(OBJ_DETECT_LABELS_TXT/$*)

run_face_detect: $(BIN)/obj_detect \
                 $(TESTDATA)/frozen_inference_graph_face.pb \
                 $(TESTDATA)/face_labels.txt
	TF_CPP_MIN_VLOG_LEVEL=$(TF_VLOG_LEVEL) $(BIN)/obj_detect \
	    --video_file=$(TESTDATA)/jurassic_world.mkv --output=jurassic_world.face.mkv \
	    --model_file=$(TESTDATA)/frozen_inference_graph_face.pb \
	    --labels_file=$(TESTDATA)/face_labels.txt

train_mnist: $(BIN)/mnist \
             $(TESTDATA)/mnist_data/train-images-idx3-ubyte \
             $(TESTDATA)/mnist_data/train-labels-idx1-ubyte \
             $(TESTDATA)/mnist_data/t10k-images-idx3-ubyte \
             $(TESTDATA)/mnist_data/t10k-labels-idx1-ubyte
	TF_CPP_MIN_VLOG_LEVEL=$(TF_VLOG_LEVEL) $(BIN)/mnist -data_dir=$(TESTDATA)/mnist_data

PREFIX?=/usr/local
BLAS?=MKL
USE_MKLDNN?=1
BLAS_CXXFLAGS/ATLAS:=-DEIGEN_USE_BLAS -DEIGEN_USE_LAPACKE
BLAS_CXXFLAGS/OpenBLAS:=-DEIGEN_USE_BLAS -DEIGEN_USE_LAPACKE
BLAS_CXXFLAGS/MKL:=-DINTEL_MKL -DEIGEN_USE_MKL_ALL -I$(PREFIX)/intel/mkl/include -I$(PREFIX)/intel/mkldnn/include
BLAS_LDFLAGS/ATLAS:=-L$(PREFIX)/ATLAS/lib -llapack -lcblas -lf77blas -latlas -lgfortran -lquadmath
BLAS_LDFLAGS/OpenBLAS:=-L$(PREFIX)/OpenBLAS/lib -Wl,-Bstatic -lopenblas -lgfortran -lquadmath -Wl,-Bdynamic
# See https://software.intel.com/en-us/articles/intel-mkl-link-line-advisor/
BLAS_LDFLAGS/MKL:=-L$(PREFIX)/intel/mkl/lib -Wl,--start-group -lmkl_intel_lp64 -lmkl_sequential -lmkl_core -Wl,--end-group
ifneq ($(USE_MKLDNN),)
	BLAS_LDFLAGS/MKL:=-L$(PREFIX)/intel/mkldnn/lib -lmkldnn $(BLAS_LDFLAGS/MKL)
else
	BLAS_CXXFLAGS/MKL += -DINTEL_MKL_ML_ONLY
endif

CXXFLAGS:=-g -O3 -pthread -std=c++11 -DNDEBUG -D_POSIX_C_SOURCE=200809L -D_FILE_OFFSET_BITS=64 \
          -fno-exceptions -funwind-tables -fvisibility-inlines-hidden -I$(PREFIX)/include/eigen3

LDFLAGS:=-Wl,-Bstatic -lbenchmark -lglog -lgflags -lstdc++ \
         -lavformat -lavcodec -lavfilter -lavdevice -lswscale -lavutil -lx264 -lz \
         -Wl,-Bdynamic -lpthread -ldl

$(BIN)/test_video.o: $(SRC)/test_video.cc $(SRC)/test_video.hpp $(SRC)/utils.hpp
	mkdir -p $(BIN)
	g++ -c $(CXXFLAGS) $< -o $@

$(BIN)/video_encoder.o: $(SRC)/video_encoder.cc $(SRC)/video_encoder.hpp $(SRC)/utils.hpp
	mkdir -p $(BIN)
	g++ -c $(CXXFLAGS) $< -o $@

$(BIN)/classify_lite.o: $(SRC)/classify_lite.cc $(SRC)/test_video.hpp $(SRC)/utils.hpp
	mkdir -p $(BIN)
	g++ -c $(CXXFLAGS) $< -o $@

$(BIN)/classify_lite: $(BIN)/test_video.o $(BIN)/classify_lite.o
	mkdir -p $(BIN)
	g++ -o $@ $^ -ltensorflow-lite -lfarmhash $(LDFLAGS)

$(BIN)/classify.o: $(SRC)/classify.cc $(SRC)/test_video.hpp $(SRC)/utils.hpp
	mkdir -p $(BIN)
	g++ -c $(CXXFLAGS) $(BLAS_CXXFLAGS/$(BLAS)) $< -o $@

$(BIN)/classify: $(BIN)/test_video.o $(BIN)/classify.o
	mkdir -p $(BIN)
	g++ -o $@ $^ -Wl,--allow-multiple-definition -Wl,--whole-archive -ltensorflow-core \
	    -Wl,--no-whole-archive -lprotobuf -lnsync_cpp -lnsync -ldouble-conversion -labsl \
        $(BLAS_LDFLAGS/$(BLAS)) $(LDFLAGS)

$(BIN)/obj_detect_lite.o: $(SRC)/obj_detect_lite.cc $(SRC)/test_video.hpp \
                          $(SRC)/video_encoder.hpp $(SRC)/utils.hpp
	mkdir -p $(BIN)
	g++ -c $(CXXFLAGS) $< -o $@

OPENCV_LDFLAGS=-lopencv_imgcodecs -lopencv_imgproc -lopencv_core \
    -L/usr/local/share/OpenCV/3rdparty/lib -lippiw -lippicv -ljpeg

$(BIN)/obj_detect_lite: $(BIN)/test_video.o $(BIN)/video_encoder.o $(BIN)/obj_detect_lite.o
	mkdir -p $(BIN)
	g++ -o $@ $^ -ltensorflow-lite -lfarmhash $(OPENCV_LDFLAGS) $(BLAS_LDFLAGS/$(BLAS)) $(LDFLAGS)

$(BIN)/obj_detect.o: obj_detect.cc test_video.hpp video_encoder.hpp utils.hpp
	mkdir -p $(BIN)
	g++ -c $(CXXFLAGS) $(BLAS_CXXFLAGS/$(BLAS)) $< -o $@

$(BIN)/obj_detect: $(BIN)/test_video.o $(BIN)/video_encoder.o $(BIN)/obj_detect.o
	mkdir -p $(BIN)
	g++ -o $@ $^ -Wl,--allow-multiple-definition -Wl,--whole-archive -ltensorflow-core \
	    -Wl,--no-whole-archive -lprotobuf -lnsync_cpp -lnsync -ldouble-conversion -labsl \
	    $(OPENCV_LDFLAGS) $(BLAS_LDFLAGS/$(BLAS)) $(LDFLAGS)

$(BIN)/simple_network.o: $(SRC)/simple_network.cc $(SRC)/simple_network.hpp $(SRC)/utils.hpp
	mkdir -p $(BIN)
	g++ -c $(CXXFLAGS) $(BLAS_CXXFLAGS/$(BLAS)) $< -o $@

$(BIN)/mnist.o: $(SRC)/mnist.cc $(SRC)/simple_network.hpp
	mkdir -p $(BIN)
	g++ -c $(CXXFLAGS) $(BLAS_CXXFLAGS/$(BLAS)) $< -o $@

$(BIN)/mnist: $(BIN)/mnist.o $(BIN)/simple_network.o
	mkdir -p $(BIN)
	g++ -o $@ $^ -Wl,--allow-multiple-definition -Wl,--whole-archive -ltensorflow-core \
	    -Wl,--no-whole-archive -lprotobuf -lnsync -ldouble-conversion \
        $(BLAS_LDFLAGS/$(BLAS)) $(LDFLAGS)

$(TESTDATA)/mobilenet_v1_%.tflite: $(PROJECT_ROOT)/models/mobilenet/v1/mobilenet_v1_%.tgz
	cd $(TESTDATA) ; tar xf $< ./mobilenet_v1_$*.tflite ; touch $@

$(TESTDATA)/mobilenet_v2_%.tflite: $(PROJECT_ROOT)/models/mobilenet/v2/mobilenet_v2_%.tgz
	cd $(TESTDATA) ; tar xf $< ./mobilenet_v2_$*.tflite ; touch $@

$(TESTDATA)/mobilenet_v1_%_frozen.pb: $(PROJECT_ROOT)/models/mobilenet/v1/mobilenet_v1_%.tgz
	cd $(TESTDATA) ; tar xf $< ./mobilenet_v1_$*_frozen.pb ; touch $@

$(TESTDATA)/mobilenet_v2_%_frozen.pb: $(PROJECT_ROOT)/models/mobilenet/v2/mobilenet_v2_%.tgz
	cd $(TESTDATA) ; tar xf $< ./mobilenet_v2_$*_frozen.pb ; touch $@

$(TESTDATA)/ssdlite_mobilenet_v2_coco10_frozen.pb: $(PROJECT_ROOT)/models/objdetect/coco10.pb
	cp $< $@

$(TESTDATA)/%_frozen.pb: $(PROJECT_ROOT)/models/objdetect/%.tar.gz
	cd $(TESTDATA) ; tar xf $< $*/frozen_inference_graph.pb -O > $@

$(PROJECT_ROOT)/models/mobilenet/v1/mobilenet_v1_%.tgz:
	wget -P $(dir $@) http://download.tensorflow.org/models/mobilenet_v1_2018_02_22/mobilenet_v1_$*.tgz

$(PROJECT_ROOT)/models/mobilenet/v2/mobilenet_v2_%.tgz:
	wget -P $(dir $@) https://storage.googleapis.com/mobilenet_v2/checkpoints/mobilenet_v2_$*.tgz

$(PROJECT_ROOT)/models/objdetect/%.tar.gz:
	wget -P $(dir $@) http://download.tensorflow.org/models/object_detection/$*.tar.gz

$(TESTDATA)/frozen_inference_graph_face.pb:
	wget -O $@ "https://github.com/yeephycho/tensorflow-face-detection/blob/master/model/frozen_inference_graph_face.pb?raw=true"

$(TESTDATA)/mobilenet_labels.txt: $(PROJECT_ROOT)/models/mobilenet/labels.txt
	cp $< $@

$(TESTDATA)/face_labels.txt:
	echo "face" > $@

$(TESTDATA)/mnist_data/%: $(TESTDATA)/mnist_data/%.gz
	gunzip -k $<

$(TESTDATA)/mnist_data/%.gz:
	mkdir -p $(dir $@)
	wget -O $@ http://yann.lecun.com/exdb/mnist/$(notdir $@)

clean:
	rm -rf bin

distclean: clean
	rm -rf $(TESTDATA)/*.pb $(TESTDATA)/*.tflite
