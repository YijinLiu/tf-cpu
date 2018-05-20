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
1. Intel(R) Core(TM) i5-5575R CPU @ 2.80GHz
w/ MKLDNN (_MklConv2D disabled)
BM_Mobilenet_v1_1_0_224_quant/min_time:5.000/manual_time         701 ms         63 ms         10 correct=70 frames=160 ms=6.924k wrong=90
BM_Mobilenet_v1_1_0_192_quant/min_time:5.000/manual_time         533 ms         70 ms         13 correct=117 frames=208 ms=6.818k wrong=91
BM_Mobilenet_v1_1_0_160_quant/min_time:5.000/manual_time         380 ms         53 ms         18 correct=126 frames=288 ms=6.69k wrong=162
BM_Mobilenet_v1_1_0_128_quant/min_time:5.000/manual_time         259 ms         45 ms         26 correct=182 frames=416 ms=6.536k wrong=234
BM_Mobilenet_v1_0_75_224_quant/min_time:5.000/manual_time        491 ms         51 ms         11 correct=88 frames=176 ms=5.313k wrong=88
BM_Mobilenet_v1_0_75_192_quant/min_time:5.000/manual_time        365 ms         52 ms         19 correct=152 frames=304 ms=6.783k wrong=152
BM_Mobilenet_v1_0_75_160_quant/min_time:5.000/manual_time        259 ms         44 ms         26 correct=182 frames=416 ms=6.511k wrong=234
BM_Mobilenet_v1_0_75_128_quant/min_time:5.000/manual_time        175 ms         39 ms         37 correct=259 frames=592 ms=6.186k wrong=333
BM_Mobilenet_v1_1_0_224/min_time:5.000/manual_time              1717 ms         94 ms          4 correct=28 frames=64 ms=6.838k wrong=36
BM_Mobilenet_v1_1_0_192/min_time:5.000/manual_time              1286 ms         89 ms          5 correct=45 frames=80 ms=6.386k wrong=35
BM_Mobilenet_v1_1_0_160/min_time:5.000/manual_time               931 ms         77 ms          6 correct=48 frames=96 ms=5.532k wrong=48
BM_Mobilenet_v1_1_0_128/min_time:5.000/manual_time               631 ms         63 ms          8 correct=56 frames=128 ms=4.976k wrong=72
BM_Mobilenet_v1_0_75_224/min_time:5.000/manual_time             1263 ms         66 ms          5 correct=40 frames=80 ms=6.281k wrong=40
BM_Mobilenet_v1_0_75_192/min_time:5.000/manual_time              943 ms         67 ms          6 correct=48 frames=96 ms=5.613k wrong=48
BM_Mobilenet_v1_0_75_160/min_time:5.000/manual_time              661 ms         54 ms          9 correct=63 frames=144 ms=5.876k wrong=81
BM_Mobilenet_v1_0_75_128/min_time:5.000/manual_time              447 ms         47 ms         12 correct=60 frames=192 ms=5.266k wrong=132
BM_Mobilenet_v2_1_4_224/min_time:5.000/manual_time              1574 ms        117 ms          4 correct=32 frames=64 ms=6.261k wrong=32
BM_Mobilenet_v2_1_3_224/min_time:5.000/manual_time              1459 ms        108 ms          4 correct=32 frames=64 ms=5.803k wrong=32
BM_Mobilenet_v2_1_0_224/min_time:5.000/manual_time              1058 ms         71 ms          6 correct=36 frames=96 ms=6.302k wrong=60
BM_Mobilenet_v2_1_0_192/min_time:5.000/manual_time               788 ms         73 ms          7 correct=56 frames=112 ms=5.46k wrong=56
BM_Mobilenet_v2_1_0_160/min_time:5.000/manual_time               565 ms         62 ms          9 correct=63 frames=144 ms=5.02k wrong=81
BM_Mobilenet_v2_1_0_128/min_time:5.000/manual_time               381 ms         46 ms         18 correct=126 frames=288 ms=6.704k wrong=162
BM_Mobilenet_v2_1_0_96/min_time:5.000/manual_time                245 ms         42 ms         27 correct=162 frames=432 ms=6.4k wrong=270
BM_Mobilenet_v2_0_75_224/min_time:5.000/manual_time              878 ms         60 ms          7 correct=49 frames=112 ms=6.095k wrong=63
BM_Mobilenet_v2_0_75_192/min_time:5.000/manual_time              661 ms         64 ms          8 correct=56 frames=128 ms=5.218k wrong=72
BM_Mobilenet_v2_0_75_160/min_time:5.000/manual_time              473 ms         54 ms         11 correct=88 frames=176 ms=5.114k wrong=88
BM_Mobilenet_v2_0_75_128/min_time:5.000/manual_time              315 ms         42 ms         22 correct=154 frames=352 ms=6.721k wrong=198
BM_Mobilenet_v2_0_75_96/min_time:5.000/manual_time               199 ms         38 ms         33 correct=66 frames=528 ms=6.294k wrong=462

w/ MKL (_MklConv2D disabled)
BM_Mobilenet_v1_1_0_224_quant/min_time:5.000/manual_time         676 ms         64 ms         10 correct=70 frames=160 ms=6.684k wrong=90
BM_Mobilenet_v1_1_0_192_quant/min_time:5.000/manual_time         510 ms         64 ms         13 correct=117 frames=208 ms=6.534k wrong=91
BM_Mobilenet_v1_1_0_160_quant/min_time:5.000/manual_time         367 ms         53 ms         19 correct=133 frames=304 ms=6.819k wrong=171
BM_Mobilenet_v1_1_0_128_quant/min_time:5.000/manual_time         249 ms         45 ms         27 correct=189 frames=432 ms=6.508k wrong=243
BM_Mobilenet_v1_0_75_224_quant/min_time:5.000/manual_time        475 ms         50 ms         11 correct=88 frames=176 ms=5.153k wrong=88
BM_Mobilenet_v1_0_75_192_quant/min_time:5.000/manual_time        352 ms         51 ms         20 correct=160 frames=320 ms=6.878k wrong=160
BM_Mobilenet_v1_0_75_160_quant/min_time:5.000/manual_time        252 ms         45 ms         27 correct=189 frames=432 ms=6.603k wrong=243
BM_Mobilenet_v1_0_75_128_quant/min_time:5.000/manual_time        170 ms         39 ms         38 correct=266 frames=608 ms=6.193k wrong=342
BM_Mobilenet_v1_1_0_224/min_time:5.000/manual_time              1123 ms         81 ms          5 correct=35 frames=80 ms=5.577k wrong=45
BM_Mobilenet_v1_1_0_192/min_time:5.000/manual_time               789 ms         75 ms          7 correct=63 frames=112 ms=5.466k wrong=49
BM_Mobilenet_v1_1_0_160/min_time:5.000/manual_time               545 ms         56 ms         13 correct=104 frames=208 ms=6.978k wrong=104
BM_Mobilenet_v1_1_0_128/min_time:5.000/manual_time               357 ms         47 ms         19 correct=133 frames=304 ms=6.637k wrong=171
BM_Mobilenet_v1_0_75_224/min_time:5.000/manual_time              664 ms         51 ms          9 correct=72 frames=144 ms=5.904k wrong=72
BM_Mobilenet_v1_0_75_192/min_time:5.000/manual_time              480 ms         55 ms         11 correct=88 frames=176 ms=5.191k wrong=88
BM_Mobilenet_v1_0_75_160/min_time:5.000/manual_time              335 ms         45 ms         20 correct=140 frames=320 ms=6.551k wrong=180
BM_Mobilenet_v1_0_75_128/min_time:5.000/manual_time              222 ms         40 ms         30 correct=150 frames=480 ms=6.422k wrong=330
BM_Mobilenet_v2_1_4_224/min_time:5.000/manual_time               966 ms         87 ms          6 correct=48 frames=96 ms=5.748k wrong=48
BM_Mobilenet_v2_1_3_224/min_time:5.000/manual_time               920 ms         82 ms          6 correct=48 frames=96 ms=5.471k wrong=48
BM_Mobilenet_v2_1_0_224/min_time:5.000/manual_time               662 ms         60 ms          8 correct=48 frames=128 ms=5.234k wrong=80
BM_Mobilenet_v2_1_0_192/min_time:5.000/manual_time               482 ms         56 ms         14 correct=112 frames=224 ms=6.627k wrong=112
BM_Mobilenet_v2_1_0_160/min_time:5.000/manual_time               341 ms         48 ms         20 correct=140 frames=320 ms=6.666k wrong=180
BM_Mobilenet_v2_1_0_128/min_time:5.000/manual_time               222 ms         41 ms         30 correct=210 frames=480 ms=6.442k wrong=270
BM_Mobilenet_v2_1_0_96/min_time:5.000/manual_time                144 ms         37 ms         44 correct=264 frames=704 ms=5.941k wrong=440
BM_Mobilenet_v2_0_75_224/min_time:5.000/manual_time              536 ms         52 ms         10 correct=70 frames=160 ms=5.282k wrong=90
BM_Mobilenet_v2_0_75_192/min_time:5.000/manual_time              398 ms         52 ms         18 correct=126 frames=288 ms=7.031k wrong=162
BM_Mobilenet_v2_0_75_160/min_time:5.000/manual_time              278 ms         45 ms         24 correct=192 frames=384 ms=6.467k wrong=192
BM_Mobilenet_v2_0_75_128/min_time:5.000/manual_time              180 ms         39 ms         36 correct=252 frames=576 ms=6.143k wrong=324
BM_Mobilenet_v2_0_75_96/min_time:5.000/manual_time               117 ms         37 ms         53 correct=106 frames=848 ms=5.786k wrong=742

w/o BLAS
BM_Mobilenet_v1_1_0_224_quant/min_time:5.000/manual_time         680 ms         65 ms         10 correct=70 frames=160 ms=6.722k wrong=90
BM_Mobilenet_v1_1_0_192_quant/min_time:5.000/manual_time         508 ms         62 ms         14 correct=126 frames=224 ms=7.003k wrong=98
BM_Mobilenet_v1_1_0_160_quant/min_time:5.000/manual_time         366 ms         54 ms         18 correct=126 frames=288 ms=6.455k wrong=162
BM_Mobilenet_v1_1_0_128_quant/min_time:5.000/manual_time         252 ms         46 ms         27 correct=189 frames=432 ms=6.585k wrong=243
BM_Mobilenet_v1_0_75_224_quant/min_time:5.000/manual_time        468 ms         50 ms         11 correct=88 frames=176 ms=5.061k wrong=88
BM_Mobilenet_v1_0_75_192_quant/min_time:5.000/manual_time        351 ms         51 ms         20 correct=160 frames=320 ms=6.848k wrong=160
BM_Mobilenet_v1_0_75_160_quant/min_time:5.000/manual_time        250 ms         45 ms         27 correct=189 frames=432 ms=6.56k wrong=243
BM_Mobilenet_v1_0_75_128_quant/min_time:5.000/manual_time        168 ms         39 ms         39 correct=273 frames=624 ms=6.295k wrong=351
BM_Mobilenet_v1_1_0_224/min_time:5.000/manual_time              2589 ms         95 ms          3 correct=21 frames=48 ms=7.743k wrong=27
BM_Mobilenet_v1_1_0_192/min_time:5.000/manual_time              1922 ms        105 ms          3 correct=27 frames=48 ms=5.741k wrong=21
BM_Mobilenet_v1_1_0_160/min_time:5.000/manual_time              1355 ms         78 ms          5 correct=40 frames=80 ms=6.741k wrong=40
BM_Mobilenet_v1_1_0_128/min_time:5.000/manual_time               887 ms         62 ms          7 correct=49 frames=112 ms=6.154k wrong=63
BM_Mobilenet_v1_0_75_224/min_time:5.000/manual_time             1886 ms         62 ms          4 correct=32 frames=64 ms=7.509k wrong=32
BM_Mobilenet_v1_0_75_192/min_time:5.000/manual_time             1401 ms         64 ms          5 correct=40 frames=80 ms=6.975k wrong=40
BM_Mobilenet_v1_0_75_160/min_time:5.000/manual_time              985 ms         56 ms          6 correct=42 frames=96 ms=5.864k wrong=54
BM_Mobilenet_v1_0_75_128/min_time:5.000/manual_time              635 ms         45 ms         10 correct=50 frames=160 ms=6.275k wrong=110
BM_Mobilenet_v2_1_4_224/min_time:5.000/manual_time              2114 ms        127 ms          3 correct=24 frames=48 ms=6.319k wrong=24
BM_Mobilenet_v2_1_3_224/min_time:5.000/manual_time              1941 ms        117 ms          3 correct=24 frames=48 ms=5.803k wrong=24
BM_Mobilenet_v2_1_0_224/min_time:5.000/manual_time              1435 ms         79 ms          4 correct=24 frames=64 ms=5.707k wrong=40
BM_Mobilenet_v2_1_0_192/min_time:5.000/manual_time              1057 ms         71 ms          6 correct=48 frames=96 ms=6.296k wrong=48
BM_Mobilenet_v2_1_0_160/min_time:5.000/manual_time               741 ms         59 ms          8 correct=56 frames=128 ms=5.873k wrong=72
BM_Mobilenet_v2_1_0_128/min_time:5.000/manual_time               487 ms         50 ms         11 correct=77 frames=176 ms=5.264k wrong=99
BM_Mobilenet_v2_1_0_96/min_time:5.000/manual_time                290 ms         41 ms         23 correct=138 frames=368 ms=6.505k wrong=230
BM_Mobilenet_v2_0_75_224/min_time:5.000/manual_time             1192 ms         60 ms          5 correct=35 frames=80 ms=5.918k wrong=45
BM_Mobilenet_v2_0_75_192/min_time:5.000/manual_time              881 ms         61 ms          7 correct=49 frames=112 ms=6.109k wrong=63
BM_Mobilenet_v2_0_75_160/min_time:5.000/manual_time              619 ms         52 ms          9 correct=72 frames=144 ms=5.5k wrong=72
BM_Mobilenet_v2_0_75_128/min_time:5.000/manual_time              407 ms         45 ms         13 correct=91 frames=208 ms=5.196k wrong=117
BM_Mobilenet_v2_0_75_96/min_time:5.000/manual_time               241 ms         37 ms         28 correct=56 frames=448 ms=6.513k wrong=392
*/
