#include <stdio.h>

#include <algorithm>
#include <chrono>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include <gflags/gflags.h>
#include <glog/logging.h>
#include <google/protobuf/io/zero_copy_stream_impl.h>
#include <opencv2/core.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <tensorflow/core/public/session.h>

#include "test_video.hpp"
#include "video_encoder.hpp"

DEFINE_string(model_file, "", "");
DEFINE_string(labels_file, "", "");

DEFINE_string(video_file, "", "");
DEFINE_string(image_files, "", "Comma separated image files");
DEFINE_int32(width, 300, "");
DEFINE_int32(height, 300, "");
DEFINE_string(output_dir, ".", "");
DEFINE_bool(output_video, true, "");
DEFINE_int32(batch_size, 1, "");

DEFINE_int32(ffmpeg_log_level, 8, "");
DEFINE_bool(output_text_graph_def, false, "");
DEFINE_int32(run_count, 1, "");

namespace {

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
const T* TensorData(const tensorflow::Tensor& tensor, int batch_index);

template<>
const float* TensorData(const tensorflow::Tensor& tensor, int batch_index) {
    int nelems = tensor.dim_size(1) * tensor.dim_size(2) * tensor.dim_size(3);
    switch (tensor.dtype()) {
        case tensorflow::DT_FLOAT:
            return tensor.flat<float>().data() + nelems * batch_index;
        default:
            LOG(FATAL) << "Should not reach here!";
    }
    return nullptr;
}

template<>
const uint8_t* TensorData(const tensorflow::Tensor& tensor, int batch_index) {
    int nelems = tensor.dim_size(1) * tensor.dim_size(2) * tensor.dim_size(3);
    switch (tensor.dtype()) {
        case tensorflow::DT_UINT8:
            return tensor.flat<uint8_t>().data() + nelems * batch_index;
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

const char num_detections[] = "num_detections";
const char detection_classes[] = "detection_classes";
const char detection_scores[] = "detection_scores";
const char detection_boxes[] = "detection_boxes";

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

    bool Init(const std::string& model_file, const std::vector<std::string>& labels) {
        // Load model.
        auto status = tensorflow::ReadBinaryProto(
            tensorflow::Env::Default(), model_file, &graph_def_);
        if (!status.ok()) {
            LOG(ERROR) << "Failed to load mode file " << model_file << status;
            return false;
        }
        if (FLAGS_output_text_graph_def) {
            std::ofstream ofs(model_file + ".txt");
            google::protobuf::io::OstreamOutputStream oos(&ofs);
            google::protobuf::TextFormat::Print(graph_def_, &oos);
            LOG(INFO) << "Written to " << model_file << ".txt";
        }

        // Create graph.
        tensorflow::SessionOptions sess_opts;
        sess_opts.config.mutable_device_count()->insert({"CPU", 1});
        sess_opts.config.set_intra_op_parallelism_threads(1);
        sess_opts.config.set_inter_op_parallelism_threads(1);
        sess_opts.config.set_allow_soft_placement(1);
        sess_opts.config.set_isolate_session_state(1);
        session_.reset(tensorflow::NewSession(sess_opts));
        status = session_->Create(graph_def_);
        if (!status.ok()) {
            LOG(ERROR) << "Failed to create graph: " << status;
            return false;
        }

        // Find input/output nodes.
        std::vector<const tensorflow::NodeDef*> placeholders;
        bool has_num_detections = false;
        bool has_detection_classes = false;
        bool has_detection_scores = false;
        bool has_detection_boxes = false;
        for (const auto& node : graph_def_.node()) {
            if (node.op() == "Placeholder") {
                placeholders.push_back(&node);
            } else if (node.name() == num_detections) {
                has_num_detections = true;
            } else if (node.name() == detection_classes) {
                has_detection_classes = true;
            } else if (node.name() == detection_scores) {
                has_detection_scores = true;
            } else if (node.name() == detection_boxes) {
                has_detection_boxes = true;
            }
        }
        if (placeholders.empty()) {
            LOG(ERROR) << "No input node found!";
            return false;
        }
        const tensorflow::NodeDef* input = placeholders[0];
        VLOG(0) << "Using input node: " << input->DebugString();
        if (!input->attr().count("dtype")) {
            LOG(ERROR) << "Input node " << input->name() << "does not have dtype.";
            return false;
        }
        input_name_ = input->name();
        input_dtype_ = input->attr().at("dtype").type();
        if (input->attr().count("shape")) {
            const auto shape = input->attr().at("shape").shape();
            input_channels_ = shape.dim(3).size();
        }

        labels_ = labels;
        return true;
    }

    bool RunVideo(const std::string& video_file, int width, int height, int batch_size,
                  const std::string& output_name, bool output_video) {
        // Open input video.
        TestVideo test_video(av_pix_fmt(), 0, 0);
        if (!test_video.Init(video_file, nullptr, true)) {
            return false;
        }
        // Open output video if needed.
        AVFrame* encode_frame = nullptr;
        std::unique_ptr<VideoEncoder> video_encoder;
        if (output_video) {
            video_encoder.reset(new VideoEncoder);
            enum AVPixelFormat pix_fmt = input_channels_ == 3 ? AV_PIX_FMT_BGR24 : AV_PIX_FMT_GRAY8;
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

        if (width == 0 && height == 0) {
            width = test_video.width();
            height = test_video.height();
        } else if (width == 0) {
            width = test_video.width() * height / test_video.height();
        } else if (height == 0) {
            height = test_video.height() * width / test_video.width();
        }
        InitInputTensor(batch_size, width, height);

        // Run.
        int frames = 0;
        int total_ms = 0;
        AVFrame* frame = nullptr;
        std::vector<std::unique_ptr<AVFrameAndMat>> batch(batch_size);
        while ((frame = test_video.NextFrame())) {
            // Feed in data.
            auto mat = AVFrameToMat(frame);
            const int batch_index = frames % batch_size;
            if (width != mat->cols || height != mat->rows) {
                cv::Mat for_tf;
                cv::resize(*mat, for_tf, cv::Size(width, height));
                FeedInMat(for_tf, batch_index);
            } else {
                FeedInMat(*mat, batch_index);
            }
            batch[batch_index].reset(new AVFrameAndMat{frame, mat.release()});
            frames++;
            if (frames % batch_size != 0) continue;

            // Run.
            std::vector<tensorflow::Tensor> output_tensors;
            const auto start = std::chrono::high_resolution_clock::now();
            if (!Run(&output_tensors)) return false;
            const std::chrono::duration<double> duration =
                std::chrono::high_resolution_clock::now() - start;
            const auto elapsed_ms =
                std::chrono::duration_cast<std::chrono::milliseconds>(duration).count();
            total_ms += elapsed_ms;
            VLOG(0) << frames << ": ms=" << elapsed_ms;

            // Annotate.
            if (input_channels_ == 3) {
                for (auto& f : batch) cv::cvtColor(*f->mat, *f->mat, cv::COLOR_RGB2BGR);
            }
            for (int i = 0; i < batch_size; i++) {
                AnnotateMat(*batch[i]->mat, output_tensors, i);
            }
            if (output_video) {
                for (int i = 0; i < batch_size; i++) {
                    const auto* mat = batch[i]->mat;
                    uint8_t* dst = encode_frame->data[0];
                    for (int row = 0; row < mat->rows; row++) {
                        memcpy(dst, mat->ptr(row), mat->cols * input_channels_);
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
               output_name.c_str(), frames, width, height, total_ms, total_ms / frames);
        return true;
    }

    bool RunImage(const std::string& file_name, const std::string& output) {
        cv::Mat mat = cv::imread(file_name);
        if (mat.empty()) {
            LOG(ERROR) << "Failed to read image " << file_name;
            return false;
        }
        std::vector<tensorflow::Tensor> output_tensors;
        cv::Mat for_tf;
        cv::cvtColor(mat, for_tf, cv::COLOR_BGR2RGB);
        const auto start = std::chrono::high_resolution_clock::now();
        InitInputTensor(1, mat.cols, mat.rows);
        FeedInMat(for_tf, 0);
        if (!Run(&output_tensors)) return false;
        const std::chrono::duration<double> duration =
            std::chrono::high_resolution_clock::now() - start;
        const auto elapsed_ms =
            std::chrono::duration_cast<std::chrono::milliseconds>(duration).count();
        printf("%s processed in %d ms.\n", file_name.c_str(), (int)elapsed_ms);
        AnnotateMat(mat, output_tensors, 0);
        cv::imwrite(output, mat);
        return true;
    }

    bool Run(std::vector<tensorflow::Tensor>* output_tensors) {
        const auto status = session_->Run(
            {{input_name_, *input_tensor_}},
            {num_detections, detection_classes, detection_scores, detection_boxes},
            {},
            output_tensors);
        if (!status.ok()) {
            LOG(ERROR) << "Failed to call Session::Run: " << status;
            return false;
        }
        return true;
    }

    void FeedInMat(const cv::Mat& mat, int batch_index) {
        const int size = mat.rows * mat.cols * input_channels_;
        switch (input_dtype_) {
            case tensorflow::DT_FLOAT:
                if (input_channels_ == 3) {
                    float* data = input_tensor_->flat<float>().data() + size * batch_index;
                    for (int row = 0; row < mat.rows; row++) {
                        for (int col = 0; col < mat.cols; col++) {
                            const cv::Vec3b& pix = mat.at<cv::Vec3b>(row, col);
                            const int pos = (row * mat.cols + col) * 3;
                            data[pos] = pix[0] / 256.f;
                            data[pos + 1] = pix[1] / 256.f;
                            data[pos + 2] = pix[2] / 256.f;
                        }
                    }
                } else {
                    float* data = input_tensor_->flat<float>().data() + size * batch_index;
                    for (int row = 0; row < mat.rows; row++) {
                        for (int col = 0; col < mat.cols; col++) {
                            data[row * mat.cols + col] = mat.at<uint8_t>(row, col) / 256.f;
                        }
                    }
                }
                break;
            case tensorflow::DT_UINT8:
                {
                    uint8_t* dst = input_tensor_->flat<uint8_t>().data() + size * batch_index;
                    const int row_elems = mat.cols * input_channels_;
                    for (int row = 0; row < mat.rows; row++) {
                        memcpy(dst, mat.ptr(row), row_elems);
                        dst += row_elems;
                    }
                }
                break;
            default:
                LOG(FATAL) << "Should not reach here!";
        }
    }

  private:
    enum AVPixelFormat av_pix_fmt() const {
        return input_channels_ == 3 ? AV_PIX_FMT_RGB24 : AV_PIX_FMT_GRAY8;
    }

    void InitInputTensor(int batch_size, int width, int height) {
        if (!input_tensor_ || input_tensor_->dim_size(1) != width ||
            input_tensor_->dim_size(2) != height) {
            // Create input tensor.
            tensorflow::TensorShape input_shape;
            input_shape.AddDim(batch_size);
            input_shape.AddDim(height);
            input_shape.AddDim(width);
            input_shape.AddDim(input_channels_);
            input_tensor_.reset(new tensorflow::Tensor(input_dtype_, input_shape));
        }
    }

    void AnnotateMat(cv::Mat& mat, const std::vector<tensorflow::Tensor>& output_tensors,
                     int batch_index) {
        const int num_detections = *TensorData<float>(output_tensors[0], batch_index);
        const float* detection_classes = TensorData<float>(output_tensors[1], batch_index);
        const float* detection_scores = TensorData<float>(output_tensors[2], batch_index);
        const float* detection_boxes = TensorData<float>(output_tensors[3], batch_index);
        for (int i = 0; i < num_detections; i++) {
            const int cls = detection_classes[i];
            const float score = detection_scores[i];
            if (cls == 0 || score < 0.51f) continue;
            const int ymin = detection_boxes[4 * i] * mat.rows;
            const int xmin = detection_boxes[4 * i + 1] * mat.cols;
            const int ymax = detection_boxes[4 * i + 2] * mat.rows;
            const int xmax = detection_boxes[4 * i + 3] * mat.cols;
            VLOG(0) << "Detected " << labels_[cls - 1] << " with score " << score
                << " @[" << xmin << "," << ymin << ":" << xmax << "," << ymax << "]";
            cv::rectangle(mat, cv::Rect(xmin, ymin, xmax - xmin, ymax - ymin),
                          cv::Scalar(0, 0, 255), 1);
            cv::putText(mat, labels_[cls - 1], cv::Point(xmin, ymin - 5),
                        cv::FONT_HERSHEY_COMPLEX, .8, cv::Scalar(10, 255, 30));
        }
    }

    std::vector<std::string> labels_;
    tensorflow::GraphDef graph_def_;
    std::unique_ptr<tensorflow::Session> session_;

    std::string input_name_;
    tensorflow::DataType input_dtype_;
    int input_channels_ = 3;
    std::unique_ptr<tensorflow::Tensor> input_tensor_;
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
    google::ParseCommandLineFlags(&argc, &argv, true);
    google::InitGoogleLogging(argv[0]);
    InitFfmpeg(FLAGS_ffmpeg_log_level);
    std::vector<std::string> labels;
    if (!ReadLines(FLAGS_labels_file, &labels)) return 1;
    ObjDetector obj_detector;
    if (!obj_detector.Init(FLAGS_model_file, labels)) return 1;
    for (int i = 0; i < FLAGS_run_count; i++) {
        if (!FLAGS_video_file.empty()) {
            obj_detector.RunVideo(FLAGS_video_file, FLAGS_width, FLAGS_height, FLAGS_batch_size,
                                  FLAGS_output_dir + "/" + filename_base(FLAGS_video_file),
                                  FLAGS_output_video);
        } else if (!FLAGS_image_files.empty()) {
            for (const std::string& img_file : split(FLAGS_image_files, ',')) {
                obj_detector.RunImage(img_file, FLAGS_output_dir + "/" + filename_base(img_file));
            }
        }
    }
}

/*
1. Intel(R) Core(TM) i3-8300 CPU @ 3.70GHz
ssd_mobilenet_v1_coco_2017_11_17/beach.mkv: 290 300x300 frames processed in 26138 ms(90 mspf).
ssd_mobilenet_v2_coco_2018_03_29/beach.mkv: 290 300x300 frames processed in 23810 ms(82 mspf).
ssdlite_mobilenet_v2_coco_2018_05_09/beach.mkv: 290 300x300 frames processed in 16252 ms(56 mspf).
ssdlite_mobilenet_v2_mixed/beach.mkv: 290 300x300 frames processed in 13609 ms(46 mspf).
*/
