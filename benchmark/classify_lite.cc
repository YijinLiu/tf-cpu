#include <chrono>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include <benchmark/benchmark.h>
#include <gflags/gflags.h>
#include <glog/logging.h>
#include <tensorflow/contrib/lite/kernels/register.h>
#include <tensorflow/contrib/lite/model.h>

#include "test_video.hpp"

DEFINE_string(testdata_dir, "testdata", "");
DEFINE_int32(ffmpeg_log_level, 16, "");

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

std::string JoinStrings(const std::vector<std::string>& items, const std::string& sep) {
    std::string result;
    for (const auto& item : items) {
        if (!result.empty()) result += sep;
        result += item;
    }
    return result;
}

void AVFrameToTensor(AVFrame* frame, TfLiteTensor* input) {
    CHECK_EQ(input->dims->size, 4);
    const int size = input->dims->data[1] * input->dims->data[2] * input->dims->data[3];
    switch (input->type) {
        case kTfLiteFloat32:
            for (int i = 0; i < size; i++) {
                input->data.f[i] = frame->data[0][i] / 256.f;
            }
            break;
        case kTfLiteUInt8:
            memcpy(input->data.uint8, frame->data[0], size);
            break;
        default:
            LOG(FATAL) << "Should not reach here!";
    }
}

template<typename T>
std::vector<int> GetTopNIndices(const T* data, int size, int n) {
    std::vector<int> topn;
    auto comp = [&](int i, int j) -> bool { return data[i] > data[j]; };
    for (int i = 0; i < size; i++) {
        topn.push_back(i);
        std::push_heap(topn.begin(), topn.end(), comp);
        if (topn.size() > n) {
            std::pop_heap(topn.begin(), topn.end(), comp);
            topn.pop_back();
        }
    }
    std::sort_heap(topn.begin(), topn.end(), comp);
    return topn;
}

std::vector<std::string> GetTopN(TfLiteTensor* output, const std::vector<std::string>& labels, int n) {
    CHECK_EQ(output->dims->size, 2);
    CHECK_EQ(output->dims->data[0], 1);
    std::vector<int> topn;
    switch (output->type) {
        case kTfLiteFloat32:
            topn = GetTopNIndices<float>(output->data.f, output->dims->data[1], n);
            break;
        case kTfLiteUInt8:
            topn = GetTopNIndices<uint8_t>(output->data.uint8, output->dims->data[1], n);
            break;
        default:
            LOG(FATAL) << "Should not reach here!";
    }
    std::vector<std::string> topn_labels(topn.size());
    for (int i = 0; i < topn.size(); i++) {
        if (topn[i] < labels.size()) topn_labels[i] = labels[topn[i]];
    }
    return topn_labels;
}

void RunInterpreter(const std::string& model_file, const std::string& labels_file,
                    const std::string& image_pat, const std::string& results_file,
                    benchmark::State& state) {
    // Load model.
    auto model = tflite::FlatBufferModel::BuildFromFile(model_file.c_str());
    if (!model) {
        state.SkipWithError("failed to load model");
        return;
    }
    // Create interpreter.
    tflite::ops::builtin::BuiltinOpResolver resolver;
    std::unique_ptr<tflite::Interpreter> interpreter;
    tflite::InterpreterBuilder(*model, resolver)(&interpreter);
    if (!interpreter) {
        state.SkipWithError("failed to create interpreter");
        return;
    }
    if (interpreter->AllocateTensors() != kTfLiteOk) {
        state.SkipWithError("failed to allocate tensors");
        return;
    }
    interpreter->SetNumThreads(1);
    // Get input / output.
    const int input = interpreter->inputs()[0];
    TfLiteTensor* input_tensor = interpreter->tensor(input);
    TfLiteIntArray* input_dims = input_tensor->dims;
    const uint32_t width = input_dims->data[1], height = input_dims->data[2];
    const enum AVPixelFormat pix_fmt =
        (input_dims->data[3] == 3 ? AV_PIX_FMT_RGB24 : AV_PIX_FMT_GRAY8);
    const int output = interpreter->outputs()[0];
    TfLiteTensor* output_tensor = interpreter->tensor(output);
    // Read labels and results.
    std::vector<std::string> labels;
    if (!ReadLines(labels_file, &labels)) {
        state.SkipWithError("failed to read labels file");
        return;
    }
    std::vector<std::string> results;
    if (!ReadLines(results_file, &results)) {
        state.SkipWithError("failed to read results file");
        return;
    }

    // Run.
    int correct = 0;
    int wrong = 0;
    int frames = 0;
    int total_ms = 0;
    for (auto _ : state) {
        TestVideo test_video(pix_fmt, width, height);
        if (!test_video.Init(image_pat, "image2", true)) {
            state.SkipWithError("failed to open test video");
            return;
        }
        int index = 0;
        double iteration_secs = 0;
        AVFrame* frame = nullptr;
        while ((frame = test_video.NextFrame())) {
            const auto start = std::chrono::high_resolution_clock::now();
            AVFrameToTensor(frame, input_tensor);
            const TfLiteStatus rc = interpreter->Invoke();
            const std::chrono::duration<double> duration =
                std::chrono::high_resolution_clock::now() - start;
            iteration_secs += duration.count();
            const auto elapsed_ms =
                std::chrono::duration_cast<std::chrono::milliseconds>(duration).count();
            total_ms += elapsed_ms;
            av_frame_free(&frame);
            if (rc != kTfLiteOk) {
                state.SkipWithError("failed to call Interpreter::Invoke!");
                return;
            }
            const auto topn = GetTopN(output_tensor, labels, 3);
            if (std::find(topn.begin(), topn.end(), results[index]) != topn.end()) {
                correct++;
            } else {
                wrong++;
            }
            frames++;
            VLOG(1) << index << ": expected=" << results[index] << ", got='" << JoinStrings(topn, "|")
                << "', ms=" << elapsed_ms;
            index++;
        }
        state.SetIterationTime(iteration_secs);
    }
    VLOG(1) << "Precision=" << (float)correct / (correct + wrong)
        << "(" << correct << "/" << correct + wrong << ").";
    state.counters["correct"] = correct;
    state.counters["wrong"] = wrong;
    state.counters["frames"] = frames;
    state.counters["ms"] = total_ms;
}

#define MOBILENET_BENCHMARK(name, file) \
void BM_Mobilenet_##name(benchmark::State& state) { \
    const std::string model_file = FLAGS_testdata_dir + "/mobilenet_" + file + ".tflite"; \
    const std::string labels_file = FLAGS_testdata_dir + "/mobilenet_labels.txt"; \
    const std::string image2_pat = FLAGS_testdata_dir + "/%03d.png"; \
    const std::string results_file = FLAGS_testdata_dir + "/results.txt"; \
    RunInterpreter(model_file, labels_file, image2_pat, results_file, state); \
} \
BENCHMARK(BM_Mobilenet_##name)->UseManualTime()->Unit(benchmark::kMillisecond)->MinTime(5.0) \

MOBILENET_BENCHMARK(v1_1_0_224_quant, "v1_1.0_224_quant");
MOBILENET_BENCHMARK(v1_1_0_192_quant, "v1_1.0_192_quant");
MOBILENET_BENCHMARK(v1_1_0_160_quant, "v1_1.0_160_quant");
MOBILENET_BENCHMARK(v1_1_0_128_quant, "v1_1.0_128_quant");

MOBILENET_BENCHMARK(v1_0_75_224_quant, "v1_0.75_224_quant");
MOBILENET_BENCHMARK(v1_0_75_192_quant, "v1_0.75_192_quant");
MOBILENET_BENCHMARK(v1_0_75_160_quant, "v1_0.75_160_quant");
MOBILENET_BENCHMARK(v1_0_75_128_quant, "v1_0.75_128_quant");

MOBILENET_BENCHMARK(v1_1_0_224, "v1_1.0_224");
MOBILENET_BENCHMARK(v1_1_0_192, "v1_1.0_192");
MOBILENET_BENCHMARK(v1_1_0_160, "v1_1.0_160");
MOBILENET_BENCHMARK(v1_1_0_128, "v1_1.0_128");

MOBILENET_BENCHMARK(v1_0_75_224, "v1_0.75_224");
MOBILENET_BENCHMARK(v1_0_75_192, "v1_0.75_192");
MOBILENET_BENCHMARK(v1_0_75_160, "v1_0.75_160");
MOBILENET_BENCHMARK(v1_0_75_128, "v1_0.75_128");

MOBILENET_BENCHMARK(v2_1_4_224, "v2_1.4_224");

MOBILENET_BENCHMARK(v2_1_3_224, "v2_1.3_224");

MOBILENET_BENCHMARK(v2_1_0_224, "v2_1.0_224");
MOBILENET_BENCHMARK(v2_1_0_192, "v2_1.0_192");
MOBILENET_BENCHMARK(v2_1_0_160, "v2_1.0_160");
MOBILENET_BENCHMARK(v2_1_0_128, "v2_1.0_128");
MOBILENET_BENCHMARK(v2_1_0_96, "v2_1.0_96");

MOBILENET_BENCHMARK(v2_0_75_224, "v2_0.75_224");
MOBILENET_BENCHMARK(v2_0_75_192, "v2_0.75_192");
MOBILENET_BENCHMARK(v2_0_75_160, "v2_0.75_160");
MOBILENET_BENCHMARK(v2_0_75_128, "v2_0.75_128");
MOBILENET_BENCHMARK(v2_0_75_96, "v2_0.75_96");

}  // namespace

int main(int argc, char** argv) {
    google::SetCommandLineOption("v", "1");
    google::ParseCommandLineFlags(&argc, &argv, true);
    google::InitGoogleLogging(argv[0]);
    benchmark::Initialize(&argc, argv);
    InitFfmpeg(FLAGS_ffmpeg_log_level);
    benchmark::RunSpecifiedBenchmarks();
}

/*
1. Intel(R) Core(TM) i3-4130 CPU @ 3.40GHz
BM_Mobilenet_v1_1_0_224_quant/min_time:5.000/manual_time         900 ms        925 ms          8 correct=64 frames=128 ms=7.129k wrong=64
BM_Mobilenet_v1_1_0_192_quant/min_time:5.000/manual_time         661 ms        694 ms         11 correct=99 frames=176 ms=7.162k wrong=77
BM_Mobilenet_v1_1_0_160_quant/min_time:5.000/manual_time         482 ms        514 ms         14 correct=84 frames=224 ms=6.653k wrong=140
BM_Mobilenet_v1_1_0_128_quant/min_time:5.000/manual_time         316 ms        346 ms         22 correct=154 frames=352 ms=6.752k wrong=198
BM_Mobilenet_v1_0_75_224_quant/min_time:5.000/manual_time        599 ms        624 ms         12 correct=36 frames=192 ms=7.084k wrong=156
BM_Mobilenet_v1_0_75_192_quant/min_time:5.000/manual_time        440 ms        474 ms         16 correct=112 frames=256 ms=6.913k wrong=144
BM_Mobilenet_v1_0_75_160_quant/min_time:5.000/manual_time        306 ms        336 ms         23 correct=138 frames=368 ms=6.847k wrong=230
BM_Mobilenet_v1_0_75_128_quant/min_time:5.000/manual_time        205 ms        234 ms         34 correct=272 frames=544 ms=6.716k wrong=272
BM_Mobilenet_v1_1_0_224/min_time:5.000/manual_time               374 ms        174 ms         20 correct=140 frames=320 ms=7.319k wrong=180
BM_Mobilenet_v1_1_0_192/min_time:5.000/manual_time               298 ms        147 ms         23 correct=207 frames=368 ms=6.659k wrong=161
BM_Mobilenet_v1_1_0_160/min_time:5.000/manual_time               216 ms        111 ms         32 correct=256 frames=512 ms=6.659k wrong=256
BM_Mobilenet_v1_1_0_128/min_time:5.000/manual_time               147 ms         83 ms         43 correct=301 frames=688 ms=5.953k wrong=387
BM_Mobilenet_v1_0_75_224/min_time:5.000/manual_time              252 ms        135 ms         29 correct=232 frames=464 ms=7.084k wrong=232
BM_Mobilenet_v1_0_75_192/min_time:5.000/manual_time              192 ms        117 ms         35 correct=280 frames=560 ms=6.451k wrong=280
BM_Mobilenet_v1_0_75_160/min_time:5.000/manual_time              145 ms         93 ms         47 correct=329 frames=752 ms=6.428k wrong=423
BM_Mobilenet_v1_0_75_128/min_time:5.000/manual_time              107 ms         73 ms         64 correct=320 frames=1024 ms=6.303k wrong=704
BM_Mobilenet_v2_1_4_224/min_time:5.000/manual_time               515 ms        282 ms         13 correct=104 frames=208 ms=6.594k wrong=104
BM_Mobilenet_v2_1_3_224/min_time:5.000/manual_time               471 ms        278 ms         15 correct=120 frames=240 ms=6.953k wrong=120
BM_Mobilenet_v2_1_0_224/min_time:5.000/manual_time               380 ms        232 ms         19 correct=114 frames=304 ms=7.071k wrong=190
BM_Mobilenet_v2_1_0_192/min_time:5.000/manual_time               295 ms        196 ms         25 correct=200 frames=400 ms=7.171k wrong=200
BM_Mobilenet_v2_1_0_160/min_time:5.000/manual_time               197 ms        152 ms         35 correct=245 frames=560 ms=6.603k wrong=315
BM_Mobilenet_v2_1_0_128/min_time:5.000/manual_time               140 ms        121 ms         53 correct=371 frames=848 ms=6.983k wrong=477
BM_Mobilenet_v2_1_0_96/min_time:5.000/manual_time                 99 ms         96 ms         68 correct=408 frames=1088 ms=6.261k wrong=680
BM_Mobilenet_v2_0_75_224/min_time:5.000/manual_time              307 ms        196 ms         22 correct=154 frames=352 ms=6.577k wrong=198
BM_Mobilenet_v2_0_75_192/min_time:5.000/manual_time              239 ms        179 ms         29 correct=203 frames=464 ms=6.689k wrong=261
BM_Mobilenet_v2_0_75_160/min_time:5.000/manual_time              161 ms        138 ms         42 correct=336 frames=672 ms=6.401k wrong=336
BM_Mobilenet_v2_0_75_128/min_time:5.000/manual_time              114 ms        105 ms         65 correct=455 frames=1040 ms=7k wrong=585
BM_Mobilenet_v2_0_75_96/min_time:5.000/manual_time                81 ms         84 ms         87 correct=174 frames=1.392k ms=6.435k wrong=1.218k
*/
