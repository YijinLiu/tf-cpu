// Run object detection model using DLDT.

#include <time.h>

#include <algorithm>
#include <chrono>
#include <fstream>
#include <memory>
#include <string>
#include <tuple>
#include <vector>

#include <ext_list.hpp>
#include <inference_engine.hpp>
#include <gflags/gflags.h>
#include <glog/logging.h>
#include <opencv2/core.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include "test_video.hpp"
#include "utils.hpp"
#include "video_encoder.hpp"

using namespace InferenceEngine;

DEFINE_string(model, "testdata/ssdlite_mobilenet_v2_coco_2018_05_09_frozen", "");
DEFINE_string(labels_file, "", "");
DEFINE_string(plugin_dir, "/usr/local/lib", "");
DEFINE_string(device, "CPU", "CPU/GPU");
DEFINE_bool(collect_perf_count, false, "");

DEFINE_string(video_file, "", "");
DEFINE_string(image_files, "", "Comma separated image files");
DEFINE_int32(width, 300, "");
DEFINE_int32(height, 300, "");
DEFINE_string(output_dir, ".", "");
DEFINE_bool(output_video, true, "");
DEFINE_int32(batch_size, 1, "");
DEFINE_int32(ffmpeg_log_level, 8, "");
DEFINE_int32(run_count, 1, "");

namespace {

bool ReadLines(const std::string& file_name, std::vector<std::string>* lines) {
    std::ifstream file(file_name);
    if (!file) {
        VLOG(-1) << "Failed to open file " << file_name;
        return false;
    }
    std::string line;
    while (std::getline(file, line)) lines->push_back(line);
    return true;
}

class ErrorListener : public InferenceEngine::IErrorListener {
  public:
    ErrorListener() {}
    
    void set_prefix(const std::string& prefix) { prefix_ = prefix; }

  private:
    void onError(const char* msg) noexcept override {
        VLOG(-1) << prefix_ << msg;
    }

    std::string prefix_;
};

std::string VersionString(const Version* version) {
    return Sprintf("%d.%d.%s(%s)", version->apiVersion.major, version->apiVersion.minor,
                   version->buildNumber, version->description);
}

// Returns a Mat that refer to the data owned by frame.
std::unique_ptr<cv::Mat> AVFrameToMat(AVFrame* frame) {
    std::unique_ptr<cv::Mat> mat;
    if (frame->format == AV_PIX_FMT_GBRP) {
        mat.reset(new cv::Mat(frame->height, frame->width, CV_8UC3));
        // G
        for (int r = 0; r < frame->height; r++) {
            const uint8_t* data = frame->data[0] + r * frame->linesize[0];
            for (int c = 0; c < frame->width; c++) {
                cv::Vec3b& pix = mat->at<cv::Vec3b>(r, c);
                pix[1] = data[c];
            }
        }
        // B
        for (int r = 0; r < frame->height; r++) {
            const uint8_t* data = frame->data[1] + r * frame->linesize[1];
            for (int c = 0; c < frame->width; c++) {
                cv::Vec3b& pix = mat->at<cv::Vec3b>(r, c);
                pix[0] = data[c];
            }
        }
        // R
        for (int r = 0; r < frame->height; r++) {
            const uint8_t* data = frame->data[2] + r * frame->linesize[3];
            for (int c = 0; c < frame->width; c++) {
                cv::Vec3b& pix = mat->at<cv::Vec3b>(r, c);
                pix[2] = data[c];
            }
        }
    } else if (frame->format == AV_PIX_FMT_GRAY8) {
        mat.reset(new cv::Mat(
            frame->height, frame->width, CV_8UC1, frame->data[0], frame->linesize[0]));
    } else {
        LOG(FATAL) << "Should not reach here!";
    }
    return mat;
}

struct AVFrameWrapper {
    ~AVFrameWrapper() {
        av_frame_free(&frame);
    }
    AVFrame* frame;
};

class ObjDetector {
  public:
    ObjDetector(const std::vector<std::string>& labels) : labels_(labels) {};

    bool Init(const std::string& model, const std::string& plugin_dir, const std::string& device) {
        VLOG(1) << "InferenceEngine: " << VersionString(GetInferenceEngineVersion());
        err_listener_.set_prefix(Sprintf("[IE %s] ", device.c_str()));
        try {
            std::map<std::string, std::string> cfgs;
            if (FLAGS_collect_perf_count) {
                cfgs[PluginConfigParams::KEY_PERF_COUNT] = PluginConfigParams::YES;
            }
            if (device == "CPU") {
                plugin_ = PluginDispatcher({plugin_dir}).getPluginByName("MKLDNNPlugin");
                cfgs[PluginConfigParams::KEY_CPU_BIND_THREAD] = PluginConfigParams::YES;
                cfgs[PluginConfigParams::KEY_CPU_THROUGHPUT_STREAMS] = "1";
            } else {
                plugin_ = PluginDispatcher({plugin_dir}).getPluginByName("clDNNPlugin");
                cfgs[PluginConfigParams::KEY_CONFIG_FILE] =
                    plugin_dir + "/cldnn_global_custom_kernels/cldnn_global_custom_kernels.xml";
            }
            plugin_.SetConfig(cfgs);
            static_cast<InferenceEnginePluginPtr>(plugin_)->SetLogCallback(err_listener_);
            if (device == "CPU") {
                VLOG(1) << "Adding CPU extension...";
                plugin_.AddExtension(std::make_shared<Extensions::Cpu::CpuExtensions>());
            }
            VLOG(1) << "InferenceEngine/" << device << ": " << VersionString(plugin_.GetVersion());

            CNNNetReader networkReader;
            networkReader.ReadNetwork(model + ".xml");
            networkReader.ReadWeights(model + ".bin");
            network_ = networkReader.getNetwork();

            const auto input_info_map = network_.getInputsInfo();
            if (input_info_map.size() != 1) {
                VLOG(-1) << "Expected 1 and only 1 input, got " << input_info_map.size();
                return false;
            }
            InputInfo::Ptr input_info = nullptr;
            std::tie(input_name_, input_info) = *input_info_map.begin();
            const auto input_dims = input_info->getTensorDesc().getDims();
            if (input_dims.size() != 4) {
                VLOG(-1) << "Expected '" << input_name_ << "' to have 4 dims, got "
                         << input_dims.size();
                return false;
            }
            input_channels_ = input_dims[1];
            input_info->setLayout(Layout::NCHW);
            input_info->setPrecision(Precision::U8);
            VLOG(1) << "Input dims: " << input_dims[0] << "x" << input_channels_ << "x"
                    << input_dims[2] << "x" << input_dims[3];

            const auto output_info_map = network_.getOutputsInfo();
            if (output_info_map.size() != 1) {
                VLOG(-1) << "Expected 1 and only 1 output, got " << output_info_map.size();
                return false;
            }
            DataPtr output_info = nullptr;
            std::tie(output_name_, output_info) = *output_info_map.begin();
            const auto output_dims = output_info->getTensorDesc().getDims();
            if (output_dims.size() != 4) {
                VLOG(-1) << "Expected '" << output_name_ << "' to have 4 dims, got "
                         << output_dims.size();
                return false;
            }
            if (output_dims[0] != input_dims[0] || output_dims[1] != 1) {
                VLOG(-1) << "Expect '" << output_name_ << "' to be " << input_dims[0] << "x1, got "
                         << output_dims[0] << "x" << output_dims[1];
                return false;
            }
            max_proposal_count_ = output_dims[2];
            const size_t object_size = output_dims[3];
            if (object_size != 7) {
                VLOG(-1) << "Expected 7 output items, got " << object_size;
                return false;
            }
            VLOG(1) << "Output dims: " << output_dims[0] << "x" << output_dims[1] << "x"
                    << output_dims[2] << "x" << output_dims[3];
            output_info->setPrecision(Precision::FP32);
        } catch (const std::exception& error) {
            VLOG(-1) << error.what();
            return false;
        } catch (...) {
            VLOG(-1) << "Unknown/internal exception happened.";
            return false;
        }

        return true;
    }

    bool RunVideo(const std::string& video_file, size_t batch_size, size_t height, size_t width,
                  const std::string& output_name, bool output_video) {
        // Open input video.
        TestVideo test_video(av_pix_fmt(), width, height);
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

        // Run.
        int frames = 0;
        int total_ms = 0;
        AVFrame* frame = nullptr;
        std::vector<std::unique_ptr<AVFrameWrapper>> batch(batch_size);
        InitNetwork(batch_size, height, width);
        while ((frame = test_video.NextFrame())) {
            // Feed in data.
            const int batch_index = frames % batch_size;
            FeedInAVFrame(frame, batch_index);
            batch[batch_index].reset(new AVFrameWrapper{frame});
            frames++;
            if (frames % batch_size != 0) continue;

            // Run.
            const auto start = std::chrono::high_resolution_clock::now();
            infer_request_.Infer();
            const std::chrono::duration<double> duration =
                std::chrono::high_resolution_clock::now() - start;
            const auto elapsed_ms =
                std::chrono::duration_cast<std::chrono::milliseconds>(duration).count();
            total_ms += elapsed_ms;
            VLOG(1) << frames << ": ms=" << elapsed_ms;

            // Annotate.
            if (output_video) {
                for (int i = 0; i < batch_size; i++) {
                    auto mat = AVFrameToMat(batch[i]->frame);
                    AnnotateMat(*mat, i);
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
                    auto mat = AVFrameToMat(batch[i]->frame);
                    AnnotateMat(*mat, i);
                    snprintf(image_file_name, sizeof(image_file_name), "%s.%05d.jpeg",
                             output_name.c_str(), (int)(frames - batch_size + i));
                    cv::imwrite(image_file_name, *mat);
                }
            }
        }
        av_frame_free(&encode_frame);
        printf("%s: %d %dx%d frames processed in %d ms(%d mspf).\n",
               output_name.c_str(), frames, (int)width, (int)height, total_ms, total_ms / frames);
        return true;
    }

    bool RunImage(const std::string& file_name, size_t height, size_t width,
                  const std::string& output) {
        cv::Mat mat = cv::imread(file_name);
        if (mat.empty()) {
            VLOG(-1) << "Failed to read image " << file_name;
            return false;
        }
        if (height > 0 && width > 0) cv::resize(mat, mat, cv::Size(width, height));
        InitNetwork(1, mat.rows, mat.cols);
        FeedInMat(mat, 0);
        const auto start = std::chrono::high_resolution_clock::now();
        infer_request_.Infer();
        const std::chrono::duration<double> duration =
            std::chrono::high_resolution_clock::now() - start;
        const auto elapsed_ms =
            std::chrono::duration_cast<std::chrono::milliseconds>(duration).count();
        printf("%s processed in %d ms.\n", file_name.c_str(), (int)elapsed_ms);
        AnnotateMat(mat, 0);
        cv::imwrite(output, mat);
        return true;
    }

    void FeedInMat(const cv::Mat& mat, int batch_index) {
        const size_t image_size = input_height_ * input_width_;
        auto* data = static_cast<uint8_t*>(input_blob_->buffer()) +
            batch_index * input_channels_ * image_size;
        if (input_channels_ == 3) {
            for (size_t r = 0; r < input_height_; r++) {
                for (size_t c = 0; c < input_width_; c++) {
                    const cv::Vec3b& pix = mat.at<cv::Vec3b>(r, c);
                    const size_t offset = r * input_width_ + c;
                    data[offset] = pix[2];
                    data[image_size + offset] = pix[1];
                    data[2* image_size + offset] = pix[0];
                }
            }
        } else {
            for (int row = 0; row < mat.rows; row++) {
                memcpy(data + row * mat.cols, mat.ptr(row), mat.cols);
            }
        }
    }

    void FeedInAVFrame(const AVFrame* frame, int batch_index) {
        const size_t image_size = input_height_ * input_width_;
        auto* data = static_cast<uint8_t*>(input_blob_->buffer()) +
            batch_index * input_channels_ * image_size;
        if (frame->format == AV_PIX_FMT_GBRP) {
            // R
            auto* dst = data;
            const uint8_t* src = frame->data[2];
            for (int r = 0; r < input_height_; r++) { 
                memcpy(dst, src, input_width_);
                dst += input_width_;
                src += frame->linesize[2];
            }
            // G
            src = frame->data[0];
            for (int r = 0; r < input_height_; r++) { 
                memcpy(dst, src, input_width_);
                dst += input_width_;
                src += frame->linesize[0];
            }
            // B
            src = frame->data[1];
            for (int r = 0; r < input_height_; r++) { 
                memcpy(dst, src, input_width_);
                dst += input_width_;
                src += frame->linesize[1];
            }
        } else if (frame->format == AV_PIX_FMT_GRAY8) {
            auto* dst = data;
            const uint8_t* src = frame->data[0];
            for (int r = 0; r < input_height_; r++) { 
                memcpy(dst, src, input_width_);
                dst += input_width_;
                src += frame->linesize[0];
            }
        } else {
            LOG(FATAL) << "Should not reach here!";
        }
    }

  private:
    enum AVPixelFormat av_pix_fmt() const {
        return input_channels_ == 3 ? AV_PIX_FMT_GBRP : AV_PIX_FMT_GRAY8;
    }

    void AnnotateMat(cv::Mat& mat, int batch_index) {
        const float* detection = static_cast<PrecisionTrait<Precision::FP32>::value_type*>(
            output_blob_->buffer()) + batch_index * max_proposal_count_ * 7;
        for (int i = 0; i < max_proposal_count_; i++, detection += 7) {
            const auto image_id = static_cast<int>(detection[0]);
            if (image_id < 0) break;
            const int cls = static_cast<int>(detection[1]);
            const float score = detection[2];
            if (cls == 0 || score < .51f) continue;
            const auto xmin = static_cast<int>(detection[3] * mat.cols);
            const auto ymin = static_cast<int>(detection[4] * mat.rows);
            const auto xmax = static_cast<int>(detection[5] * mat.cols);
            const auto ymax = static_cast<int>(detection[6] * mat.rows);
            VLOG(1) << "Detected " << labels_[cls - 1] << " with score " << score
                    << " @[" << xmin << "," << ymin << ":" << xmax << "," << ymax << "]";
            cv::rectangle(mat, cv::Rect(xmin, ymin, xmax - xmin, ymax - ymin),
                          cv::Scalar(0, 0, 255), 1);
            cv::putText(mat, labels_[cls - 1], cv::Point(xmin, ymin - 5),
                        cv::FONT_HERSHEY_COMPLEX, .8, cv::Scalar(10, 255, 30));
        }
    }

    void InitNetwork(size_t batch_size, size_t height, size_t width) {
        if (batch_size != batch_size_ || input_height_ != height || input_width_ != width) {
            auto input_shapes = network_.getInputShapes();
            SizeVector& input_shape = input_shapes[input_name_];
            input_shape[0] = batch_size;
            input_shape[2] = height;
            input_shape[3] = width;
            network_.reshape(input_shapes);
            exe_network_ = plugin_.LoadNetwork(network_, {});
            infer_request_ = exe_network_.CreateInferRequest();
            input_blob_ = infer_request_.GetBlob(input_name_);
            output_blob_ = infer_request_.GetBlob(output_name_);
            batch_size_ = batch_size;
            input_height_ = height;
            input_width_ = width;
        }
    }

    const std::vector<std::string> labels_;
    ErrorListener err_listener_;
    InferencePlugin plugin_;
    CNNNetwork network_;
    ExecutableNetwork exe_network_;
    InferRequest infer_request_;
    std::string input_name_, output_name_;
    size_t batch_size_, input_channels_ = 3, input_height_ = 0, input_width_ = 0;
    size_t max_proposal_count_ = 0;
    Blob::Ptr input_blob_;
    Blob::Ptr output_blob_;
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

int main(int argc, char *argv[]) {
    google::ParseCommandLineFlags(&argc, &argv, true);
    google::InitGoogleLogging(argv[0]);
    InitFfmpeg(FLAGS_ffmpeg_log_level);
    std::vector<std::string> labels;
    if (!ReadLines(FLAGS_labels_file, &labels)) return 1;
    ObjDetector obj_detector(labels);
    if (!obj_detector.Init(FLAGS_model, FLAGS_plugin_dir, FLAGS_device)) return 1;
    for (int i = 0; i < FLAGS_run_count; i++) {
        if (!FLAGS_video_file.empty()) {
            obj_detector.RunVideo(FLAGS_video_file, FLAGS_batch_size, FLAGS_height, FLAGS_width,
                                  FLAGS_output_dir + "/" + filename_base(FLAGS_video_file),
                                  FLAGS_output_video);
        } else if (!FLAGS_image_files.empty()) {
            for (const std::string& img_file : split(FLAGS_image_files, ',')) {
                obj_detector.RunImage(img_file, FLAGS_height, FLAGS_width,
                                      FLAGS_output_dir + "/" + filename_base(img_file));
            }
        }
    }
}

/*
1. Intel(R) Core(TM) i3-8300 CPU @ 3.70GHz
ssdlite_mobilenet_v2_coco_2018_05_09/beach.mkv: 290 300x300 frames processed in 6380 ms(22 mspf).
ssdlite_mobilenet_v2_mixed_dldt/beach.mkv: 290 300x300 frames processed in 4640 ms(16 mspf).
*/
