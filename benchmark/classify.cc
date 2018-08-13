#include <algorithm>
#include <chrono>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include <benchmark/benchmark.h>
#include <gflags/gflags.h>
#include <tensorflow/core/public/session.h>

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

void AVFrameToTensor(AVFrame* frame, tensorflow::Tensor* tensor) {
    CHECK_EQ(tensor->dims(), 4);
    const int size = tensor->NumElements();
    const int row_elems = frame->width * tensor->dim_size(3);
    switch (tensor->dtype()) {
        case tensorflow::DT_FLOAT:
            {
                float* data = tensor->flat<float>().data();
                for (int i = 0; i < size; i++) {
                    const int row = i / row_elems;
                    const int pos = row * frame->linesize[0] + (i % row_elems);
                    data[i] = frame->data[0][pos] / 256.f;
                }
                break;
            }
        case tensorflow::DT_UINT8:
            {
                uint8_t* dst = tensor->flat<uint8_t>().data();
                uint8_t* src = frame->data[0];
                for (int row = 0; row < frame->height; row++) {
                    memcpy(dst, src, row_elems);
                    dst += row_elems;
                    src += frame->linesize[0];
                }
            }
            break;
        default:
            LOG(FATAL) << "Should not reach here!";
    }
}

std::string InputNodeName(const std::string& input_name) {
    int start = 0;
    if (input_name[0] == '^') start = 1;
    const auto end = input_name.find_first_of(':', start);
    if (end == std::string::npos) return input_name.substr(start);
    return input_name.substr(start, end - start);
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

std::vector<std::string> GetTopN(const tensorflow::Tensor& tensor,
                                 const std::vector<std::string>& labels, int n) {
    CHECK_EQ(tensor.dims(), 2);
    CHECK_EQ(tensor.dim_size(0), 1);
    std::vector<int> topn;
    switch (tensor.dtype()) {
        case tensorflow::DT_FLOAT:
            topn = GetTopNIndices<float>(tensor.flat<float>().data(), tensor.NumElements(), n);
            break;
        case tensorflow::DT_UINT8:
            topn = GetTopNIndices<uint8_t>(tensor.flat<uint8_t>().data(), tensor.NumElements(), n);
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

void RunInterpreter(const std::string& model_file, uint32_t width, uint32_t height,
                    const std::string& labels_file, const std::string& image_pat,
                    const std::string& results_file, benchmark::State& state) {
    // Load model.
    tensorflow::GraphDef graph_def;
    if (!tensorflow::ReadBinaryProto(tensorflow::Env::Default(), model_file, &graph_def).ok()) {
        state.SkipWithError("failed to load model");
        return;
    }

    // Create graph.
    std::unique_ptr<tensorflow::Session> session;
    tensorflow::SessionOptions sess_opts;
    sess_opts.config.mutable_device_count()->insert({"CPU", 1});
    sess_opts.config.set_intra_op_parallelism_threads(1);
    sess_opts.config.set_inter_op_parallelism_threads(1);
    sess_opts.config.set_allow_soft_placement(1);
    sess_opts.config.set_isolate_session_state(1);
    session.reset(tensorflow::NewSession(sess_opts));
    const auto status = session->Create(graph_def);
    if (!status.ok()) {
        const std::string msg = "failed to create graph: " + status.error_message();
        state.SkipWithError(msg.c_str());
        return;
    }

    // Find input and output nodes.
    std::vector<const tensorflow::NodeDef*> placeholders;
    std::map<std::string, size_t> output_map;
    for (const auto& node : graph_def.node()) {
        if (node.op() == "Placeholder") placeholders.push_back(&node);
        for (const auto& input : node.input()) output_map[InputNodeName(input)]++;
    }
    if (placeholders.empty()) {
        state.SkipWithError("no input found from graph");
        return;
    }
    std::vector<std::string> output_names;
    for (const auto& node : graph_def.node()) {
        if (output_map[node.name()] == 0 &&
            node.op() != "Const" && node.op() != "Assign" &&
            node.op() != "NoOp" && node.op() != "Placeholder") {
            output_names.push_back(node.name());
            VLOG(0) << "Using output node: " << node.DebugString();
        }
    }
    if (output_names.empty()) {
        state.SkipWithError("no output found from graph");
        return;
    }

    // Create input tensor.
    const tensorflow::NodeDef* input = placeholders[0];
    VLOG(0) << "Using input node " << input->DebugString();
    if (!input->attr().count("dtype")) {
        state.SkipWithError("input node doesn't have dtype");
        return;
    }
    int channel = 3;
    if (input->attr().count("shape")) {
        const auto shape = input->attr().at("shape").shape();
        width = shape.dim(1).size();
        height = shape.dim(2).size();
        channel = shape.dim(3).size();
    }
    tensorflow::TensorShape input_shape;
    // batch size
    input_shape.AddDim(1);
    input_shape.AddDim(height);
    input_shape.AddDim(width);
    // channel.
    input_shape.AddDim(channel);
    const auto input_dtype = input->attr().at("dtype").type();
    tensorflow::Tensor input_tensor(input_dtype, input_shape);
    enum AVPixelFormat pix_fmt = (channel == 3 ? AV_PIX_FMT_RGB24 : AV_PIX_FMT_GRAY8);

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
        double iteration_secs = 0;
        int index = 0;
        AVFrame* frame = nullptr;
        while ((frame = test_video.NextFrame())) {
            std::vector<tensorflow::Tensor> output_tensors;
            const auto start = std::chrono::high_resolution_clock::now();
            AVFrameToTensor(frame, &input_tensor);
            const auto status = session->Run(
                {{input->name(), input_tensor}}, output_names, {}, &output_tensors);
            const std::chrono::duration<double> duration =
                std::chrono::high_resolution_clock::now() - start;
            iteration_secs += duration.count();
            const auto elapsed_ms =
                std::chrono::duration_cast<std::chrono::milliseconds>(duration).count();
            total_ms += elapsed_ms;
            av_frame_free(&frame);
            if (!status.ok()) {
                state.SkipWithError("failed to call Session::Run!");
                return;
            }
            const auto topn = GetTopN(output_tensors[0], labels, 3);
            if (std::find(topn.begin(), topn.end(), results[index]) != topn.end()) {
                correct++;
            } else {
                wrong++;
            }
            frames++;
            VLOG(0) << index << ": expected=" << results[index] << ", got='" << JoinStrings(topn, "|")
                << "', ms=" << elapsed_ms;
            index++;
        }
        state.SetIterationTime(iteration_secs);
    }
    VLOG(0) << "Precision=" << (float)correct / (correct + wrong)
        << "(" << correct << "/" << correct + wrong << ").";
    state.counters["correct"] = correct;
    state.counters["wrong"] = wrong;
    state.counters["frames"] = frames;
    state.counters["ms"] = total_ms;
}

#define MOBILENET_BENCHMARK(name, file, width, height) \
void BM_Mobilenet_##name(benchmark::State& state) { \
    const std::string model_file = FLAGS_testdata_dir + "/mobilenet_" + file + "_frozen.pb"; \
    const std::string labels_file = FLAGS_testdata_dir + "/mobilenet_labels.txt"; \
    const std::string image2_pat = FLAGS_testdata_dir + "/%03d.png"; \
    const std::string results_file = FLAGS_testdata_dir + "/results.txt"; \
    RunInterpreter(model_file, width, height, labels_file, image2_pat, results_file, state); \
} \
BENCHMARK(BM_Mobilenet_##name)->UseManualTime()->Unit(benchmark::kMillisecond)->MinTime(5.0) \

MOBILENET_BENCHMARK(v1_1_0_224_quant, "v1_1.0_224_quant", 224, 224);
MOBILENET_BENCHMARK(v1_1_0_192_quant, "v1_1.0_192_quant", 192, 192);
MOBILENET_BENCHMARK(v1_1_0_160_quant, "v1_1.0_160_quant", 160, 160);
MOBILENET_BENCHMARK(v1_1_0_128_quant, "v1_1.0_128_quant", 128, 128);

MOBILENET_BENCHMARK(v1_0_75_224_quant, "v1_0.75_224_quant", 224, 224);
MOBILENET_BENCHMARK(v1_0_75_192_quant, "v1_0.75_192_quant", 192, 192);
MOBILENET_BENCHMARK(v1_0_75_160_quant, "v1_0.75_160_quant", 160, 160);
MOBILENET_BENCHMARK(v1_0_75_128_quant, "v1_0.75_128_quant", 128, 128);

MOBILENET_BENCHMARK(v1_1_0_224, "v1_1.0_224", 224, 224);
MOBILENET_BENCHMARK(v1_1_0_192, "v1_1.0_192", 192, 192);
MOBILENET_BENCHMARK(v1_1_0_160, "v1_1.0_160", 160, 160);
MOBILENET_BENCHMARK(v1_1_0_128, "v1_1.0_128", 128, 128);

MOBILENET_BENCHMARK(v1_0_75_224, "v1_0.75_224", 224, 224);
MOBILENET_BENCHMARK(v1_0_75_192, "v1_0.75_192", 192, 192);
MOBILENET_BENCHMARK(v1_0_75_160, "v1_0.75_160", 160, 160);
MOBILENET_BENCHMARK(v1_0_75_128, "v1_0.75_128", 128, 128);

MOBILENET_BENCHMARK(v2_1_4_224, "v2_1.4_224", 224, 224);

MOBILENET_BENCHMARK(v2_1_3_224, "v2_1.3_224", 224, 224);

MOBILENET_BENCHMARK(v2_1_0_224, "v2_1.0_224", 224, 224);
MOBILENET_BENCHMARK(v2_1_0_192, "v2_1.0_192", 192, 192);
MOBILENET_BENCHMARK(v2_1_0_160, "v2_1.0_160", 160, 160);
MOBILENET_BENCHMARK(v2_1_0_128, "v2_1.0_128", 128, 128);
MOBILENET_BENCHMARK(v2_1_0_96, "v2_1.0_96", 96, 96);

MOBILENET_BENCHMARK(v2_0_75_224, "v2_0.75_224", 224, 224);
MOBILENET_BENCHMARK(v2_0_75_192, "v2_0.75_192", 192, 192);
MOBILENET_BENCHMARK(v2_0_75_160, "v2_0.75_160", 160, 160);
MOBILENET_BENCHMARK(v2_0_75_128, "v2_0.75_128", 128, 128);
MOBILENET_BENCHMARK(v2_0_75_96, "v2_0.75_96", 96, 96);

}  // namespace

int main(int argc, char** argv) {
    google::ParseCommandLineFlags(&argc, &argv, true);
    benchmark::Initialize(&argc, argv);
    InitFfmpeg(FLAGS_ffmpeg_log_level);
    benchmark::RunSpecifiedBenchmarks();
}

/*
1. Intel(R) Core(TM) i3-4130 CPU @ 3.40GHz
w/ MKL (_MklConv2D disabled)
BM_Mobilenet_v1_1_0_224_quant/min_time:5.000/manual_time         749 ms         80 ms          9 correct=63 frames=144 ms=6.673k wrong=81
BM_Mobilenet_v1_1_0_192_quant/min_time:5.000/manual_time         547 ms         77 ms         12 correct=108 frames=192 ms=6.461k wrong=84
BM_Mobilenet_v1_1_0_160_quant/min_time:5.000/manual_time         403 ms         62 ms         17 correct=119 frames=272 ms=6.714k wrong=153
BM_Mobilenet_v1_1_0_128_quant/min_time:5.000/manual_time         275 ms         51 ms         25 correct=175 frames=400 ms=6.663k wrong=225
BM_Mobilenet_v1_0_75_224_quant/min_time:5.000/manual_time        518 ms         58 ms         13 correct=104 frames=208 ms=6.632k wrong=104
BM_Mobilenet_v1_0_75_192_quant/min_time:5.000/manual_time        371 ms         60 ms         18 correct=144 frames=288 ms=6.542k wrong=144
BM_Mobilenet_v1_0_75_160_quant/min_time:5.000/manual_time        267 ms         48 ms         26 correct=182 frames=416 ms=6.736k wrong=234
BM_Mobilenet_v1_0_75_128_quant/min_time:5.000/manual_time        182 ms         42 ms         34 correct=238 frames=544 ms=5.977k wrong=306
BM_Mobilenet_v1_1_0_224/min_time:5.000/manual_time               769 ms         89 ms          7 correct=49 frames=112 ms=5.323k wrong=63
BM_Mobilenet_v1_1_0_192/min_time:5.000/manual_time               547 ms         76 ms         12 correct=108 frames=192 ms=6.465k wrong=84
BM_Mobilenet_v1_1_0_160/min_time:5.000/manual_time               391 ms         61 ms         16 correct=128 frames=256 ms=6.13k wrong=128
BM_Mobilenet_v1_1_0_128/min_time:5.000/manual_time               272 ms         49 ms         25 correct=175 frames=400 ms=6.59k wrong=225
BM_Mobilenet_v1_0_75_224/min_time:5.000/manual_time              499 ms         57 ms         13 correct=104 frames=208 ms=6.385k wrong=104
BM_Mobilenet_v1_0_75_192/min_time:5.000/manual_time              376 ms         58 ms         18 correct=144 frames=288 ms=6.628k wrong=144
BM_Mobilenet_v1_0_75_160/min_time:5.000/manual_time              269 ms         49 ms         25 correct=175 frames=400 ms=6.524k wrong=225
BM_Mobilenet_v1_0_75_128/min_time:5.000/manual_time              180 ms         41 ms         35 correct=175 frames=560 ms=6.117k wrong=385
BM_Mobilenet_v2_1_4_224/min_time:5.000/manual_time              1035 ms        124 ms          5 correct=40 frames=80 ms=5.135k wrong=40
BM_Mobilenet_v2_1_3_224/min_time:5.000/manual_time               919 ms         98 ms          7 correct=56 frames=112 ms=6.375k wrong=56
BM_Mobilenet_v2_1_0_224/min_time:5.000/manual_time               655 ms         76 ms          8 correct=48 frames=128 ms=5.171k wrong=80
BM_Mobilenet_v2_1_0_192/min_time:5.000/manual_time               469 ms         63 ms         15 correct=120 frames=240 ms=6.909k wrong=120
BM_Mobilenet_v2_1_0_160/min_time:5.000/manual_time               338 ms         54 ms         20 correct=140 frames=320 ms=6.616k wrong=180
BM_Mobilenet_v2_1_0_128/min_time:5.000/manual_time               221 ms         46 ms         28 correct=196 frames=448 ms=5.957k wrong=252
BM_Mobilenet_v2_1_0_96/min_time:5.000/manual_time                148 ms         40 ms         41 correct=246 frames=656 ms=5.739k wrong=410
BM_Mobilenet_v2_0_75_224/min_time:5.000/manual_time              537 ms         57 ms         13 correct=91 frames=208 ms=6.879k wrong=117
BM_Mobilenet_v2_0_75_192/min_time:5.000/manual_time              393 ms         59 ms         17 correct=119 frames=272 ms=6.545k wrong=153
BM_Mobilenet_v2_0_75_160/min_time:5.000/manual_time              269 ms         49 ms         24 correct=192 frames=384 ms=6.285k wrong=192
BM_Mobilenet_v2_0_75_128/min_time:5.000/manual_time              190 ms         43 ms         34 correct=238 frames=544 ms=6.225k wrong=306
BM_Mobilenet_v2_0_75_96/min_time:5.000/manual_time               118 ms         39 ms         49 correct=98 frames=784 ms=5.376k wrong=686
*/
