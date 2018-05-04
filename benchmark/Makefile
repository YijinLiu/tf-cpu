.SECONDARY:

PROJECT_ROOT:=$(shell readlink -f $(dir $(lastword $(MAKEFILE_LIST)))/..)
BIN:=$(PROJECT_ROOT)/benchmark/bin
TESTDATA:=$(PROJECT_ROOT)/benchmark/testdata

all: run_classify_lite run_classify run_obj_detect

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

run_obj_detect: $(BIN)/obj_detect \
                $(TESTDATA)/ssd_mobilenet_v1_coco_2017_11_17_frozen.pb \
                $(TESTDATA)/ssd_mobilenet_v2_coco_2018_03_29_frozen.pb
	TF_CPP_MIN_VLOG_LEVEL=$(TF_VLOG_LEVEL) $(BIN)/obj_detect \
	    --image_file=$(TESTDATA)/dogs.jpeg --output=dogs.ssd_mobilenet_v1_coco.jpeg \
	    --model_file=$(TESTDATA)/ssd_mobilenet_v1_coco_2017_11_17_frozen.pb \
	    --labels_file=$(PROJECT_ROOT)/models/objdetect/coco_labels.txt
	TF_CPP_MIN_VLOG_LEVEL=$(TF_VLOG_LEVEL) $(BIN)/obj_detect \
	    --image_file=$(TESTDATA)/dogs.jpeg --output=dogs.ssd_mobilenet_v2_coco.jpeg \
	    --model_file=$(TESTDATA)/ssd_mobilenet_v2_coco_2018_03_29_frozen.pb \
	    --labels_file=$(PROJECT_ROOT)/models/objdetect/coco_labels.txt
	TF_CPP_MIN_VLOG_LEVEL=$(TF_VLOG_LEVEL) $(BIN)/obj_detect \
	    --image_file=$(TESTDATA)/beach.jpeg --output=beach.ssd_mobilenet_v1_coco.jpeg \
	    --model_file=$(TESTDATA)/ssd_mobilenet_v1_coco_2017_11_17_frozen.pb \
	    --labels_file=$(PROJECT_ROOT)/models/objdetect/coco_labels.txt
	TF_CPP_MIN_VLOG_LEVEL=$(TF_VLOG_LEVEL) $(BIN)/obj_detect \
	    --image_file=$(TESTDATA)/beach.jpeg --output=beach.ssd_mobilenet_v2_coco.jpeg \
	    --model_file=$(TESTDATA)/ssd_mobilenet_v2_coco_2018_03_29_frozen.pb \
	    --labels_file=$(PROJECT_ROOT)/models/objdetect/coco_labels.txt
	TF_CPP_MIN_VLOG_LEVEL=$(TF_VLOG_LEVEL) $(BIN)/obj_detect \
	    --video_file=$(TESTDATA)/beach.mkv --output=beach.ssd_mobilenet_v1_coco.mkv \
	    --model_file=$(TESTDATA)/ssd_mobilenet_v1_coco_2017_11_17_frozen.pb \
	    --labels_file=$(PROJECT_ROOT)/models/objdetect/coco_labels.txt
	TF_CPP_MIN_VLOG_LEVEL=$(TF_VLOG_LEVEL) $(BIN)/obj_detect \
	    --video_file=$(TESTDATA)/beach.mkv --output=beach.ssd_mobilenet_v2_coco.mkv \
	    --model_file=$(TESTDATA)/ssd_mobilenet_v2_coco_2018_03_29_frozen.pb \
	    --labels_file=$(PROJECT_ROOT)/models/objdetect/coco_labels.txt

PREFIX?=/usr/local
BLAS?=MKL
BLAS_LDFLAGS/ATLAS:=-L$(PREFIX)/ATLAS/lib -llapack -lcblas -lf77blas -latlas -lgfortran -lquadmath
BLAS_LDFLAGS/OpenBLAS:=-L$(PREFIX)/OpenBLAS/lib -Wl,-Bstatic -lopenblas -lgfortran -lquadmath -Wl,-Bdynamic
# See https://software.intel.com/en-us/articles/intel-mkl-link-line-advisor/
BLAS_LDFLAGS/MKL:=-L$(PREFIX)/intel/mkl/lib -L$(PREFIX)/intel/mkldnn/lib -lmkldnn \
    -Wl,--start-group -lmkl_intel_lp64 -lmkl_sequential -lmkl_core -Wl,--end-group

CXXFLAGS:=-g -O3 -pthread -std=c++11 -DNDEBUG -D_POSIX_C_SOURCE=200809L -D_FILE_OFFSET_BITS=64 \
          -fno-exceptions -funwind-tables -fvisibility-inlines-hidden -I$(PREFIX)/include/eigen3

LDFLAGS:=-Wl,-Bstatic -lbenchmark -lglog -lgflags -lstdc++ \
         -lavformat -lavcodec -lavfilter -lavdevice -lswscale -lavutil -lx264 -lz \
         -Wl,-Bdynamic -lpthread -ldl

$(BIN)/test_video.o: test_video.cc test_video.hpp utils.hpp
	mkdir -p $(BIN)
	g++ -c $(CXXFLAGS) $< -o $@

$(BIN)/video_encoder.o: video_encoder.cc video_encoder.hpp utils.hpp
	mkdir -p $(BIN)
	g++ -c $(CXXFLAGS) $< -o $@

$(BIN)/classify_lite.o: classify_lite.cc test_video.hpp utils.hpp
	mkdir -p $(BIN)
	g++ -c $(CXXFLAGS) $< -o $@

$(BIN)/classify_lite: $(BIN)/test_video.o $(BIN)/classify_lite.o
	mkdir -p $(BIN)
	g++ -o $@ $^ -ltensorflow-lite -lfarmhash $(LDFLAGS)

$(BIN)/classify.o: classify.cc test_video.hpp utils.hpp
	mkdir -p $(BIN)
	g++ -c $(CXXFLAGS) $(BLAS_CXXFLAGS/$(BLAS)) $< -o $@

$(BIN)/classify: $(BIN)/test_video.o $(BIN)/classify.o
	mkdir -p $(BIN)
	g++ -o $@ $^ -Wl,--allow-multiple-definition -Wl,--whole-archive -ltensorflow-core \
	    -Wl,--no-whole-archive -lprotobuf -lnsync $(BLAS_LDFLAGS/$(BLAS)) $(LDFLAGS)

$(BIN)/obj_detect.o: obj_detect.cc test_video.hpp video_encoder.hpp utils.hpp
	mkdir -p $(BIN)
	g++ -c $(CXXFLAGS) $(BLAS_CXXFLAGS/$(BLAS)) $< -o $@

OPENCV_LDFLAGS=-lopencv_imgcodecs -lopencv_imgproc -lopencv_core \
    -L/usr/local/share/OpenCV/3rdparty/lib -lippiw -lippicv -llibjpeg

$(BIN)/obj_detect: $(BIN)/test_video.o $(BIN)/video_encoder.o $(BIN)/obj_detect.o
	mkdir -p $(BIN)
	g++ -o $@ $^ -Wl,--allow-multiple-definition -Wl,--whole-archive -ltensorflow-core \
	    -Wl,--no-whole-archive -lprotobuf -lnsync $(OPENCV_LDFLAGS) \
	    $(BLAS_LDFLAGS/$(BLAS)) $(LDFLAGS)

$(TESTDATA)/mobilenet_v1_%.tflite: $(PROJECT_ROOT)/models/mobilenet/v1/mobilenet_v1_%.tgz
	cd $(TESTDATA) ; tar xf $< ./mobilenet_v1_$*.tflite ; touch $@

$(TESTDATA)/mobilenet_v2_%.tflite: $(PROJECT_ROOT)/models/mobilenet/v2/mobilenet_v2_%.tgz
	cd $(TESTDATA) ; tar xf $< ./mobilenet_v2_$*.tflite ; touch $@

$(TESTDATA)/mobilenet_v1_%_frozen.pb: $(PROJECT_ROOT)/models/mobilenet/v1/mobilenet_v1_%.tgz
	cd $(TESTDATA) ; tar xf $< ./mobilenet_v1_$*_frozen.pb ; touch $@

$(TESTDATA)/mobilenet_v2_%_frozen.pb: $(PROJECT_ROOT)/models/mobilenet/v2/mobilenet_v2_%.tgz
	cd $(TESTDATA) ; tar xf $< ./mobilenet_v2_$*_frozen.pb ; touch $@

$(TESTDATA)/%_frozen.pb: $(PROJECT_ROOT)/models/objdetect/%.tar.gz
	cd $(TESTDATA) ; tar xf $< $*/frozen_inference_graph.pb -O > $@

$(PROJECT_ROOT)/models/mobilenet/v1/mobilenet_v1_%.tgz:
	wget -P $(dir $@) http://download.tensorflow.org/models/mobilenet_v1_2018_02_22/mobilenet_v1_$*.tgz

$(PROJECT_ROOT)/models/mobilenet/v2/mobilenet_v2_%.tgz:
	wget -P $(dir $@) https://storage.googleapis.com/mobilenet_v2/checkpoints/mobilenet_v2_$*.tgz

$(PROJECT_ROOT)/models/objdetect/%.tar.gz:
	wget -P $(dir $@) http://download.tensorflow.org/models/object_detection/$*.tar.gz

$(TESTDATA)/mobilenet_labels.txt: $(PROJECT_ROOT)/models/mobilenet/labels.txt
	cp $< $@

clean:
	rm -rf bin
