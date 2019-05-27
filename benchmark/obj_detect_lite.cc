// Refer to
// https://github.com/tensorflow/examples/blob/master/lite/examples/object_detection/android/app/src/main/java/org/tensorflow/lite/examples/detection/tflite/TFLiteObjectDetectionAPIModel.java
// if it doesn't work.

#include <math.h>
#include <stdio.h>

#include <algorithm>
#include <chrono>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include <gflags/gflags.h>
#include <glog/logging.h>
#include <opencv2/core.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <tensorflow/lite/kernels/register.h>
#include <tensorflow/lite/model.h>

#include "test_video.hpp"
#include "video_encoder.hpp"

DEFINE_string(model_file, "", "");
DEFINE_bool(is_quantized_model, false, "");
DEFINE_string(labels_file, "", "");

DEFINE_string(video_file, "", "");
DEFINE_string(image_files, "", "Comma separated image files");
DEFINE_string(output_dir, ".", "");
DEFINE_bool(output_video, true, "");
DEFINE_int32(batch_size, 1, "");

DEFINE_int32(ffmpeg_log_level, 8, "");

namespace {

#define IMAGE_MEAN 128.0f
#define IMAGE_STD 128.0f

bool ReadLines(const std::string& file_name, std::vector<std::string>* lines) {
    std::ifstream file(file_name);
    if (!file) {
        LOG(ERROR) << "Failed to open file " << file_name;
        return false;
    }
    std::string line;
    while (std::getline(file, line)) lines->push_back(line);
    return true;
}

template<typename T>
T* TensorData(TfLiteTensor* tensor, int batch_index);

template<>
float* TensorData(TfLiteTensor* tensor, int batch_index) {
    int nelems = 1;
    for (int i = 1; i < tensor->dims->size; i++) nelems *= tensor->dims->data[i];
    switch (tensor->type) {
        case kTfLiteFloat32:
            return tensor->data.f + nelems * batch_index;
        default:
            LOG(FATAL) << "Should not reach here!";
    }
    return nullptr;
}

template<>
uint8_t* TensorData(TfLiteTensor* tensor, int batch_index) {
    int nelems = 1;
    for (int i = 1; i < tensor->dims->size; i++) nelems *= tensor->dims->data[i];
    switch (tensor->type) {
        case kTfLiteUInt8:
            return tensor->data.uint8 + nelems * batch_index;
        default:
            LOG(FATAL) << "Should not reach here!";
    }
    return nullptr;
}

// Returns a Mat that refer to the data owned by frame.
std::unique_ptr<cv::Mat> AVFrameToMat(AVFrame* frame) {
    std::unique_ptr<cv::Mat> mat;
    if (frame->format == AV_PIX_FMT_RGB24) {
        mat.reset(new cv::Mat(
            frame->height, frame->width, CV_8UC3, frame->data[0], frame->linesize[0]));
        cv::cvtColor(*mat, *mat, cv::COLOR_RGB2BGR);
    } else if (frame->format == AV_PIX_FMT_GRAY8) {
        mat.reset(new cv::Mat(
            frame->height, frame->width, CV_8UC1, frame->data[0], frame->linesize[0]));
    } else {
        LOG(FATAL) << "Should not reach here!";
    }
    return mat;
}

struct AVFrameAndMat {
    ~AVFrameAndMat() {
        delete mat;
        av_frame_free(&frame);
    }

    AVFrame* frame;
    cv::Mat* mat;
};

class ObjDetector {
  public:
    ObjDetector() {};

    bool Init(const std::string& model_file, bool is_quantized,
              const std::vector<std::string>& labels) {
        // Load model.
        model_ = tflite::FlatBufferModel::BuildFromFile(model_file.c_str());
        if (!model_) {
            LOG(ERROR) << "Failed to load model: " << model_file;
            return false;
        }

        // Create interpreter.
        tflite::ops::builtin::BuiltinOpResolver resolver;
        tflite::InterpreterBuilder(*model_, resolver)(&interpreter_);
        if (!interpreter_) {
            LOG(ERROR) << "Failed to create interpreter!";
            return false;
        }
        if (interpreter_->AllocateTensors() != kTfLiteOk) {
            LOG(ERROR) << "Failed to allocate tensors!";
            return false;
        }
        interpreter_->SetNumThreads(1);

        // Find input tensors.
        if (interpreter_->inputs().size() != 1) {
            LOG(ERROR) << "Graph needs to have 1 and only 1 input!";
            return false;
        }
        input_tensor_ = interpreter_->tensor(interpreter_->inputs()[0]);
        if (is_quantized) {
            if (input_tensor_->type != kTfLiteUInt8) {
                LOG(ERROR) << "Quantized graph's input should be kTfLiteUInt8!";
                return false;
            }
        } else {
            if (input_tensor_->type != kTfLiteFloat32) {
                LOG(ERROR) << "Quantized graph's input should be kTfLiteFloat32!";
                return false;
            }
        }

        // Find output tensors.
        if (interpreter_->outputs().size() != 4) {
            LOG(ERROR) << "Graph needs to have 4 and only 4 outputs!";
            return false;
        }
        output_locations_ = interpreter_->tensor(interpreter_->outputs()[0]);
        output_classes_ = interpreter_->tensor(interpreter_->outputs()[1]);
        output_scores_ = interpreter_->tensor(interpreter_->outputs()[2]);
        num_detections_ = interpreter_->tensor(interpreter_->outputs()[3]);

        labels_ = labels;
        return true;
    }


    bool RunVideo(const std::string& video_file, int batch_size,
                  const std::string& output_name, bool output_video) {
        // Open input video.
        TestVideo test_video(decode_pix_fmt(), 0, 0);
        if (!test_video.Init(video_file, nullptr, true)) {
            return false;
        }

        // Open output video if needed.
        AVFrame* encode_frame = nullptr;
        std::unique_ptr<VideoEncoder> video_encoder;
        if (output_video) {
            video_encoder.reset(new VideoEncoder);
            enum AVPixelFormat pix_fmt = encode_pix_fmt();
            if (!video_encoder->Init(pix_fmt, test_video.width(), test_video.height(),
                                     test_video.time_base(), output_name)) {
                return false;
            }
            encode_frame = av_frame_alloc();
            encode_frame->width = test_video.width();
            encode_frame->height = test_video.height();
            encode_frame->format = pix_fmt;
            av_frame_get_buffer(encode_frame, 0);
        }

        // Run.
        int frames = 0;
        int total_ms = 0;
        AVFrame* frame = nullptr;
        std::vector<std::unique_ptr<AVFrameAndMat>> batch(batch_size);
        while ((frame = test_video.NextFrame())) {
            // Feed in data.
            auto mat = AVFrameToMat(frame);
            const int batch_index = frames % batch_size;
            if (width() != mat->cols || height() != mat->rows) {
                cv::Mat for_tf;
                cv::resize(*mat, for_tf, cv::Size(width(), height()));
                FeedInMat(for_tf, batch_index);
            } else {
                FeedInMat(*mat, batch_index);
            }
            batch[batch_index].reset(new AVFrameAndMat{frame, mat.release()});
            frames++;
            if (frames % batch_size != 0) continue;

            // Run.
            const auto start = std::chrono::high_resolution_clock::now();
            if (interpreter_->Invoke() != kTfLiteOk) return false;
            const std::chrono::duration<double> duration =
                std::chrono::high_resolution_clock::now() - start;
            const auto elapsed_ms =
                std::chrono::duration_cast<std::chrono::milliseconds>(duration).count();
            total_ms += elapsed_ms;
            VLOG(0) << frames << ": ms=" << elapsed_ms;

            // Annotate.
            if (input_channels() == 3) {
                for (auto& f : batch) cv::cvtColor(*f->mat, *f->mat, cv::COLOR_RGB2BGR);
            }
            for (int i = 0; i < batch_size; i++) {
                AnnotateMat(*batch[i]->mat, i);
            }
            if (output_video) {
                for (int i = 0; i < batch_size; i++) {
                    const auto* mat = batch[i]->mat;
                    uint8_t* dst = encode_frame->data[0];
                    for (int row = 0; row < mat->rows; row++) {
                        memcpy(dst, mat->ptr(row), mat->cols * input_channels());
                        dst += encode_frame->linesize[0];
                    }
                    encode_frame->pts = batch[i]->frame->pts;
                    video_encoder->EncodeAVFrame(encode_frame);
                }
            } else {
                char image_file_name[1000];
                for (int i = 0; i < batch_size; i++) {
                    snprintf(image_file_name, sizeof(image_file_name), "%s.%05d.jpeg",
                             output_name.c_str(), frames - batch_size + i);
                    cv::imwrite(image_file_name, *batch[i]->mat);
                }
            }
        }
        av_frame_free(&encode_frame);
        printf("%s: %d %dx%d frames processed in %d ms(%d mspf).\n",
               output_name.c_str(), frames, width(), height(), total_ms, total_ms / frames);
        return true;
    }

    bool RunImage(const std::string file_name, const std::string& output) {
        cv::Mat mat = cv::imread(file_name);
        if (!mat.data) {
            LOG(ERROR) << "Failed to read image " << file_name;
            return false;
        }
        if (width() != mat.cols || height() != mat.rows) {
            cv::Mat resized;
            cv::resize(mat, resized, cv::Size(width(), height()));
            cv::cvtColor(resized, resized, cv::COLOR_BGR2RGB);
            FeedInMat(resized, 0);
        } else {
            cv::Mat for_tf;
            cv::cvtColor(mat, for_tf, cv::COLOR_BGR2RGB);
            FeedInMat(for_tf, 0);
        }
        if (interpreter_->Invoke() != kTfLiteOk) return false;
        AnnotateMat(mat, 0);
        cv::imwrite(output, mat);
        return true;
    }

  private:
    int width() const {
        return input_tensor_->dims->data[2];
    }

    int height() const {
        return input_tensor_->dims->data[1];
    }

    int input_channels() const {
        return input_tensor_->dims->data[3];
    }

    enum AVPixelFormat decode_pix_fmt() const {
        return input_channels() == 3 ? AV_PIX_FMT_RGB24 : AV_PIX_FMT_GRAY8;
    }

    enum AVPixelFormat encode_pix_fmt() const {
        return input_channels() == 3 ? AV_PIX_FMT_BGR24 : AV_PIX_FMT_GRAY8;
    }

    void FeedInMat(const cv::Mat& mat, int batch_index) {
        switch (input_tensor_->type) {
            case kTfLiteFloat32:
                {
                    float* dst = TensorData<float>(input_tensor_, batch_index);
                    const int row_elems = width() * input_channels();
                    for (int row = 0; row < height(); row++) {
                        const uchar* row_ptr = mat.ptr(row);
                        for (int i = 0; i < row_elems; i++) {
                            dst[i] = (row_ptr[i] - IMAGE_MEAN) / IMAGE_STD;
                        }
                        dst += row_elems;
                    }
                }
                break;
            case kTfLiteUInt8:
                {
                    uint8_t* dst = TensorData<uint8_t>(input_tensor_, batch_index);
                    const int row_elems = width() * input_channels();
                    for (int row = 0; row < height(); row++) {
                        memcpy(dst, mat.ptr(row), row_elems);
                        dst += row_elems;
                    }
                }
                break;
            default:
                LOG(FATAL) << "Should not reach here!";
        }
    }

    void AnnotateMat(cv::Mat& mat, int batch_index) {
        const float* detection_locations = TensorData<float>(output_locations_, batch_index);
        const float* detection_classes = TensorData<float>(output_classes_, batch_index);
        const float* detection_scores = TensorData<float>(output_scores_, batch_index);
        const int num_detections = *TensorData<float>(num_detections_, batch_index);
        for (int d = 0; d < num_detections; d++) {
            const std::string cls = labels_[detection_classes[d]];
            const float score = detection_scores[d];
            const int ymin = detection_locations[4 * d] * mat.rows;
            const int xmin = detection_locations[4 * d + 1] * mat.cols;
            const int ymax = detection_locations[4 * d + 2] * mat.rows;
            const int xmax = detection_locations[4 * d + 3] * mat.cols;
            if (score < .3f) {
                VLOG(3) << "Ignore detection " << d << " of '" << cls << "' with score " << score
                    << " @[" << xmin << "," << ymin << ":" << xmax << "," << ymax << "]";
            } else {
                VLOG(0) << "Detected " << d << " of '" << cls << "' with score " << score
                    << " @[" << xmin << "," << ymin << ":" << xmax << "," << ymax << "]";
                cv::rectangle(mat, cv::Rect(xmin, ymin, xmax - xmin, ymax - ymin),
                              cv::Scalar(0, 0, 255), 1);
                cv::putText(mat, cls, cv::Point(xmin, ymin - 5),
                            cv::FONT_HERSHEY_COMPLEX, .8, cv::Scalar(10, 255, 30));
            }
        }
    }

    std::unique_ptr<tflite::FlatBufferModel> model_;
    std::unique_ptr<tflite::Interpreter> interpreter_;
    std::vector<std::string> labels_;

    TfLiteTensor* input_tensor_ = nullptr;
    TfLiteTensor* output_locations_ = nullptr;
    TfLiteTensor* output_classes_ = nullptr;
    TfLiteTensor* output_scores_ = nullptr;
    TfLiteTensor* num_detections_ = nullptr;
};

std::vector<std::string> split(const std::string& s, char delimiter) {
    std::vector<std::string> tokens;
    std::string token;
    std::istringstream token_stream(s);
    while (std::getline(token_stream, token, delimiter)) tokens.push_back(token);
    return tokens;
}

std::string filename_base(const std::string& filename) {
    std::string filename_copy(filename);
    return basename(filename_copy.data());
}

}  // namespace

int main(int argc, char** argv) {
    google::SetCommandLineOption("v", "1");
    google::SetCommandLineOption("logtostderr", "1");
    google::ParseCommandLineFlags(&argc, &argv, true);
    google::InitGoogleLogging(argv[0]);
    InitFfmpeg(FLAGS_ffmpeg_log_level);
    std::vector<std::string> labels;
    if (!ReadLines(FLAGS_labels_file, &labels)) return 1;
    ObjDetector obj_detector;
    if (!obj_detector.Init(FLAGS_model_file, FLAGS_is_quantized_model, labels)) return 1;
    if (!FLAGS_video_file.empty()) {
        obj_detector.RunVideo(FLAGS_video_file, FLAGS_batch_size,
                              FLAGS_output_dir + "/" + filename_base(FLAGS_video_file),
                              FLAGS_output_video);
    } else if (!FLAGS_image_files.empty()) {
        for (const std::string& img_file : split(FLAGS_image_files, ',')) {
            obj_detector.RunImage(img_file, FLAGS_output_dir + "/" + filename_base(img_file));
        }
    }
}

/*
1. Intel(R) Core(TM) i3-8300 CPU @ 3.70GHz
ssdlite_mobilenet_v2_coco10_lite/beach.mkv: 290 300x300 frames processed in 7843 ms(27 mspf).
ssdlite_mobilenet_v2_mixed_lite/beach.mkv: 290 300x300 frames processed in 7845 ms(27 mspf).
*/
