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
w/ MKL
BM_Mobilenet_v1_1_0_224_quant/min_time:5.000/manual_time        1082 ms         93 ms          5 correct=35 frames=80 ms=5.375k wrong=45
BM_Mobilenet_v1_1_0_192_quant/min_time:5.000/manual_time         869 ms         87 ms          6 correct=54 frames=96 ms=5.17k wrong=42
BM_Mobilenet_v1_1_0_160_quant/min_time:5.000/manual_time         721 ms         79 ms          7 correct=49 frames=112 ms=4.99k wrong=63
BM_Mobilenet_v1_1_0_128_quant/min_time:5.000/manual_time         585 ms         57 ms         12 correct=84 frames=192 ms=6.912k wrong=108
BM_Mobilenet_v1_0_75_224_quant/min_time:5.000/manual_time        727 ms         53 ms          8 correct=64 frames=128 ms=5.751k wrong=64
BM_Mobilenet_v1_0_75_192_quant/min_time:5.000/manual_time        610 ms         60 ms          9 correct=72 frames=144 ms=5.422k wrong=72
BM_Mobilenet_v1_0_75_160_quant/min_time:5.000/manual_time        478 ms         48 ms         14 correct=98 frames=224 ms=6.581k wrong=126
BM_Mobilenet_v1_0_75_128_quant/min_time:5.000/manual_time        400 ms         44 ms         17 correct=119 frames=272 ms=6.651k wrong=153
BM_Mobilenet_v1_1_0_224/min_time:5.000/manual_time              1136 ms         71 ms          5 correct=35 frames=80 ms=5.641k wrong=45
BM_Mobilenet_v1_1_0_192/min_time:5.000/manual_time               896 ms         68 ms          7 correct=63 frames=112 ms=6.214k wrong=49
BM_Mobilenet_v1_1_0_160/min_time:5.000/manual_time               709 ms         60 ms          8 correct=64 frames=128 ms=5.609k wrong=64
BM_Mobilenet_v1_1_0_128/min_time:5.000/manual_time               575 ms         55 ms          9 correct=63 frames=144 ms=5.101k wrong=81
BM_Mobilenet_v1_0_75_224/min_time:5.000/manual_time              724 ms         47 ms          8 correct=64 frames=128 ms=5.729k wrong=64
BM_Mobilenet_v1_0_75_192/min_time:5.000/manual_time              577 ms         51 ms         10 correct=80 frames=160 ms=5.687k wrong=80
BM_Mobilenet_v1_0_75_160/min_time:5.000/manual_time              482 ms         48 ms         11 correct=77 frames=176 ms=5.211k wrong=99
BM_Mobilenet_v1_0_75_128/min_time:5.000/manual_time              434 ms         45 ms         13 correct=65 frames=208 ms=5.532k wrong=143
BM_Mobilenet_v2_1_4_224/min_time:5.000/manual_time              1788 ms        144 ms          3 correct=24 frames=48 ms=5.336k wrong=24
BM_Mobilenet_v2_1_3_224/min_time:5.000/manual_time              1527 ms         98 ms          4 correct=32 frames=64 ms=6.078k wrong=32
BM_Mobilenet_v2_1_0_224/min_time:5.000/manual_time              1120 ms         66 ms          5 correct=30 frames=80 ms=5.559k wrong=50
BM_Mobilenet_v2_1_0_192/min_time:5.000/manual_time               914 ms         69 ms          6 correct=48 frames=96 ms=5.432k wrong=48
BM_Mobilenet_v2_1_0_160/min_time:5.000/manual_time               768 ms         62 ms          7 correct=49 frames=112 ms=5.321k wrong=63
BM_Mobilenet_v2_1_0_128/min_time:5.000/manual_time               669 ms         57 ms          8 correct=56 frames=128 ms=5.282k wrong=72
BM_Mobilenet_v2_1_0_96/min_time:5.000/manual_time                603 ms         57 ms          9 correct=54 frames=144 ms=5.36k wrong=90
BM_Mobilenet_v2_0_75_224/min_time:5.000/manual_time             1015 ms         71 ms          5 correct=35 frames=80 ms=5.037k wrong=45
BM_Mobilenet_v2_0_75_192/min_time:5.000/manual_time              825 ms         62 ms          7 correct=49 frames=112 ms=5.718k wrong=63
BM_Mobilenet_v2_0_75_160/min_time:5.000/manual_time              704 ms         56 ms          8 correct=64 frames=128 ms=5.561k wrong=64
BM_Mobilenet_v2_0_75_128/min_time:5.000/manual_time              598 ms         51 ms          9 correct=63 frames=144 ms=5.311k wrong=81
BM_Mobilenet_v2_0_75_96/min_time:5.000/manual_time               583 ms         49 ms         10 correct=20 frames=160 ms=5.751k wrong=140

w/o MKL
BM_Mobilenet_v1_1_0_224_quant/min_time:5.000/manual_time         722 ms         70 ms          7 correct=49 frames=112 ms=4.998k wrong=63
BM_Mobilenet_v1_1_0_192_quant/min_time:5.000/manual_time         526 ms         61 ms         13 correct=117 frames=208 ms=6.728k wrong=91
BM_Mobilenet_v1_1_0_160_quant/min_time:5.000/manual_time         374 ms         50 ms         18 correct=126 frames=288 ms=6.595k wrong=162
BM_Mobilenet_v1_1_0_128_quant/min_time:5.000/manual_time         257 ms         43 ms         26 correct=182 frames=416 ms=6.463k wrong=234
BM_Mobilenet_v1_0_75_224_quant/min_time:5.000/manual_time        471 ms         44 ms         11 correct=88 frames=176 ms=5.107k wrong=88
BM_Mobilenet_v1_0_75_192_quant/min_time:5.000/manual_time        361 ms         49 ms         20 correct=160 frames=320 ms=7.065k wrong=160
BM_Mobilenet_v1_0_75_160_quant/min_time:5.000/manual_time        254 ms         42 ms         26 correct=182 frames=416 ms=6.391k wrong=234
BM_Mobilenet_v1_0_75_128_quant/min_time:5.000/manual_time        174 ms         38 ms         35 correct=245 frames=560 ms=5.794k wrong=315
BM_Mobilenet_v1_1_0_224/min_time:5.000/manual_time              2545 ms         94 ms          3 correct=21 frames=48 ms=7.609k wrong=27
BM_Mobilenet_v1_1_0_192/min_time:5.000/manual_time              1929 ms        101 ms          3 correct=27 frames=48 ms=5.761k wrong=21
BM_Mobilenet_v1_1_0_160/min_time:5.000/manual_time              1386 ms         92 ms          4 correct=32 frames=64 ms=5.517k wrong=32
BM_Mobilenet_v1_1_0_128/min_time:5.000/manual_time               926 ms         61 ms          7 correct=49 frames=112 ms=6.424k wrong=63
BM_Mobilenet_v1_0_75_224/min_time:5.000/manual_time             1822 ms         59 ms          4 correct=32 frames=64 ms=7.256k wrong=32
BM_Mobilenet_v1_0_75_192/min_time:5.000/manual_time             1412 ms         65 ms          5 correct=40 frames=80 ms=7.018k wrong=40
BM_Mobilenet_v1_0_75_160/min_time:5.000/manual_time              987 ms         54 ms          7 correct=49 frames=112 ms=6.849k wrong=63
BM_Mobilenet_v1_0_75_128/min_time:5.000/manual_time              622 ms         46 ms          9 correct=45 frames=144 ms=5.527k wrong=99
BM_Mobilenet_v2_1_4_224/min_time:5.000/manual_time              2100 ms        122 ms          3 correct=24 frames=48 ms=6.278k wrong=24
BM_Mobilenet_v2_1_3_224/min_time:5.000/manual_time              1899 ms        109 ms          3 correct=24 frames=48 ms=5.676k wrong=24
BM_Mobilenet_v2_1_0_224/min_time:5.000/manual_time              1361 ms         61 ms          5 correct=30 frames=80 ms=6.768k wrong=50
BM_Mobilenet_v2_1_0_192/min_time:5.000/manual_time              1024 ms         66 ms          6 correct=48 frames=96 ms=6.093k wrong=48
BM_Mobilenet_v2_1_0_160/min_time:5.000/manual_time               717 ms         54 ms          8 correct=56 frames=128 ms=5.674k wrong=72
BM_Mobilenet_v2_1_0_128/min_time:5.000/manual_time               503 ms         49 ms         11 correct=77 frames=176 ms=5.454k wrong=99
BM_Mobilenet_v2_1_0_96/min_time:5.000/manual_time                285 ms         40 ms         23 correct=138 frames=368 ms=6.362k wrong=230
BM_Mobilenet_v2_0_75_224/min_time:5.000/manual_time             1143 ms         50 ms          6 correct=42 frames=96 ms=6.809k wrong=54
BM_Mobilenet_v2_0_75_192/min_time:5.000/manual_time              854 ms         57 ms          7 correct=49 frames=112 ms=5.919k wrong=63
BM_Mobilenet_v2_0_75_160/min_time:5.000/manual_time              602 ms         50 ms          9 correct=72 frames=144 ms=5.343k wrong=72
BM_Mobilenet_v2_0_75_128/min_time:5.000/manual_time              413 ms         43 ms         13 correct=91 frames=208 ms=5.274k wrong=117
BM_Mobilenet_v2_0_75_96/min_time:5.000/manual_time               234 ms         36 ms         28 correct=56 frames=448 ms=6.29k wrong=392

2. Intel(R) Celeron(R) CPU N3350 @ 1.10GHz
w/ MKL
BM_Mobilenet_v1_1_0_224_quant/min_time:5.000/manual_time       11400 ms        959 ms          1 correct=7 frames=16 ms=11.393k wrong=9
BM_Mobilenet_v1_1_0_192_quant/min_time:5.000/manual_time        9993 ms        892 ms          1 correct=9 frames=16 ms=9.984k wrong=7
BM_Mobilenet_v1_1_0_160_quant/min_time:5.000/manual_time        9213 ms        846 ms          1 correct=6 frames=16 ms=9.204k wrong=10
BM_Mobilenet_v1_1_0_128_quant/min_time:5.000/manual_time        8678 ms        844 ms          1 correct=7 frames=16 ms=8.67k wrong=9
BM_Mobilenet_v1_0_75_224_quant/min_time:5.000/manual_time       3355 ms        338 ms          2 correct=16 frames=32 ms=6.695k wrong=16
BM_Mobilenet_v1_0_75_192_quant/min_time:5.000/manual_time       2826 ms        350 ms          2 correct=16 frames=32 ms=5.635k wrong=16
BM_Mobilenet_v1_0_75_160_quant/min_time:5.000/manual_time       2297 ms        249 ms          3 correct=21 frames=48 ms=6.872k wrong=27
BM_Mobilenet_v1_0_75_128_quant/min_time:5.000/manual_time       1981 ms        246 ms          3 correct=21 frames=48 ms=5.917k wrong=27
BM_Mobilenet_v1_1_0_224/min_time:5.000/manual_time             11140 ms        701 ms          1 correct=7 frames=16 ms=11.133k wrong=9
BM_Mobilenet_v1_1_0_192/min_time:5.000/manual_time              9885 ms        688 ms          1 correct=9 frames=16 ms=9.878k wrong=7
BM_Mobilenet_v1_1_0_160/min_time:5.000/manual_time              8933 ms        694 ms          1 correct=8 frames=16 ms=8.924k wrong=8
BM_Mobilenet_v1_1_0_128/min_time:5.000/manual_time              8299 ms        691 ms          1 correct=7 frames=16 ms=8.29k wrong=9
BM_Mobilenet_v1_0_75_224/min_time:5.000/manual_time             3451 ms        267 ms          2 correct=16 frames=32 ms=6.886k wrong=16
BM_Mobilenet_v1_0_75_192/min_time:5.000/manual_time             2895 ms        284 ms          2 correct=16 frames=32 ms=5.772k wrong=16
BM_Mobilenet_v1_0_75_160/min_time:5.000/manual_time             2346 ms        207 ms          3 correct=21 frames=48 ms=7.017k wrong=27
BM_Mobilenet_v1_0_75_128/min_time:5.000/manual_time             2033 ms        207 ms          3 correct=15 frames=48 ms=6.074k wrong=33
BM_Mobilenet_v2_1_4_224/min_time:5.000/manual_time              7823 ms        979 ms          1 correct=8 frames=16 ms=7.813k wrong=8
BM_Mobilenet_v2_1_3_224/min_time:5.000/manual_time              6969 ms        830 ms          1 correct=8 frames=16 ms=6.962k wrong=8
BM_Mobilenet_v2_1_0_224/min_time:5.000/manual_time              4337 ms        335 ms          2 correct=12 frames=32 ms=8.656k wrong=20
BM_Mobilenet_v2_1_0_192/min_time:5.000/manual_time              3597 ms        363 ms          2 correct=16 frames=32 ms=7.18k wrong=16
BM_Mobilenet_v2_1_0_160/min_time:5.000/manual_time              2973 ms        355 ms          2 correct=14 frames=32 ms=5.926k wrong=18
BM_Mobilenet_v2_1_0_128/min_time:5.000/manual_time              2371 ms        256 ms          3 correct=21 frames=48 ms=7.087k wrong=27
BM_Mobilenet_v2_1_0_96/min_time:5.000/manual_time               2044 ms        256 ms          3 correct=18 frames=48 ms=6.108k wrong=30
BM_Mobilenet_v2_0_75_224/min_time:5.000/manual_time             3364 ms        300 ms          2 correct=14 frames=32 ms=6.712k wrong=18
BM_Mobilenet_v2_0_75_192/min_time:5.000/manual_time             2784 ms        331 ms          2 correct=14 frames=32 ms=5.553k wrong=18
BM_Mobilenet_v2_0_75_160/min_time:5.000/manual_time             2230 ms        239 ms          3 correct=24 frames=48 ms=6.666k wrong=24
BM_Mobilenet_v2_0_75_128/min_time:5.000/manual_time             1864 ms        234 ms          3 correct=21 frames=48 ms=5.569k wrong=27
BM_Mobilenet_v2_0_75_96/min_time:5.000/manual_time              1571 ms        192 ms          4 correct=8 frames=64 ms=6.251k wrong=56

3. Intel(R) Core(TM) i7-5557U CPU @ 3.10GHz
w/ MKL
BM_Mobilenet_v1_1_0_224_quant/min_time:5.000/manual_time         903 ms         63 ms          8 correct=56 frames=128 ms=7.164k wrong=72
BM_Mobilenet_v1_1_0_192_quant/min_time:5.000/manual_time         729 ms         75 ms          7 correct=63 frames=112 ms=5.042k wrong=49
BM_Mobilenet_v1_1_0_160_quant/min_time:5.000/manual_time         586 ms         56 ms         12 correct=84 frames=192 ms=6.941k wrong=108
BM_Mobilenet_v1_1_0_128_quant/min_time:5.000/manual_time         484 ms         51 ms         14 correct=98 frames=224 ms=6.672k wrong=126
BM_Mobilenet_v1_0_75_224_quant/min_time:5.000/manual_time        618 ms         48 ms          9 correct=72 frames=144 ms=5.489k wrong=72
BM_Mobilenet_v1_0_75_192_quant/min_time:5.000/manual_time        501 ms         54 ms         10 correct=80 frames=160 ms=4.921k wrong=80
BM_Mobilenet_v1_0_75_160_quant/min_time:5.000/manual_time        402 ms         44 ms         17 correct=119 frames=272 ms=6.746k wrong=153
BM_Mobilenet_v1_0_75_128_quant/min_time:5.000/manual_time        334 ms         39 ms         21 correct=147 frames=336 ms=6.878k wrong=189
BM_Mobilenet_v1_1_0_224/min_time:5.000/manual_time               979 ms         63 ms          6 correct=42 frames=96 ms=5.831k wrong=54
BM_Mobilenet_v1_1_0_192/min_time:5.000/manual_time               765 ms         68 ms          7 correct=63 frames=112 ms=5.302k wrong=49
BM_Mobilenet_v1_1_0_160/min_time:5.000/manual_time               614 ms         59 ms          9 correct=72 frames=144 ms=5.46k wrong=72
BM_Mobilenet_v1_1_0_128/min_time:5.000/manual_time               489 ms         46 ms         14 correct=98 frames=224 ms=6.759k wrong=126
BM_Mobilenet_v1_0_75_224/min_time:5.000/manual_time              651 ms         43 ms          9 correct=72 frames=144 ms=5.794k wrong=72
BM_Mobilenet_v1_0_75_192/min_time:5.000/manual_time              515 ms         49 ms         11 correct=88 frames=176 ms=5.567k wrong=88
BM_Mobilenet_v1_0_75_160/min_time:5.000/manual_time              432 ms         46 ms         12 correct=84 frames=192 ms=5.096k wrong=108
BM_Mobilenet_v1_0_75_128/min_time:5.000/manual_time              344 ms         38 ms         20 correct=100 frames=320 ms=6.722k wrong=220
BM_Mobilenet_v2_1_4_224/min_time:5.000/manual_time              1463 ms        104 ms          4 correct=32 frames=64 ms=5.825k wrong=32
BM_Mobilenet_v2_1_3_224/min_time:5.000/manual_time              1312 ms         81 ms          5 correct=40 frames=80 ms=6.522k wrong=40
BM_Mobilenet_v2_1_0_224/min_time:5.000/manual_time               989 ms         59 ms          6 correct=36 frames=96 ms=5.885k wrong=60
BM_Mobilenet_v2_1_0_192/min_time:5.000/manual_time               804 ms         63 ms          7 correct=56 frames=112 ms=5.575k wrong=56
BM_Mobilenet_v2_1_0_160/min_time:5.000/manual_time               670 ms         57 ms          8 correct=56 frames=128 ms=5.287k wrong=72
BM_Mobilenet_v2_1_0_128/min_time:5.000/manual_time               561 ms         52 ms          9 correct=63 frames=144 ms=4.994k wrong=81
BM_Mobilenet_v2_1_0_96/min_time:5.000/manual_time                481 ms         48 ms         11 correct=66 frames=176 ms=5.191k wrong=110
BM_Mobilenet_v2_0_75_224/min_time:5.000/manual_time              848 ms         51 ms          7 correct=49 frames=112 ms=5.882k wrong=63
BM_Mobilenet_v2_0_75_192/min_time:5.000/manual_time              721 ms         58 ms          8 correct=56 frames=128 ms=5.706k wrong=72
BM_Mobilenet_v2_0_75_160/min_time:5.000/manual_time              605 ms         53 ms          9 correct=72 frames=144 ms=5.365k wrong=72
BM_Mobilenet_v2_0_75_128/min_time:5.000/manual_time              511 ms         46 ms         11 correct=77 frames=176 ms=5.518k wrong=99
BM_Mobilenet_v2_0_75_96/min_time:5.000/manual_time               452 ms         44 ms         12 correct=24 frames=192 ms=5.314k wrong=168

w/o MKL
BM_Mobilenet_v1_1_0_224_quant/min_time:5.000/manual_time         664 ms         71 ms          8 correct=56 frames=128 ms=5.24k wrong=72
BM_Mobilenet_v1_1_0_192_quant/min_time:5.000/manual_time         476 ms         62 ms         14 correct=126 frames=224 ms=6.517k wrong=98
BM_Mobilenet_v1_1_0_160_quant/min_time:5.000/manual_time         343 ms         52 ms         20 correct=140 frames=320 ms=6.674k wrong=180
BM_Mobilenet_v1_1_0_128_quant/min_time:5.000/manual_time         236 ms         44 ms         27 correct=189 frames=432 ms=6.151k wrong=243
BM_Mobilenet_v1_0_75_224_quant/min_time:5.000/manual_time        453 ms         47 ms         16 correct=128 frames=256 ms=7.133k wrong=128
BM_Mobilenet_v1_0_75_192_quant/min_time:5.000/manual_time        330 ms         51 ms         21 correct=168 frames=336 ms=6.75k wrong=168
BM_Mobilenet_v1_0_75_160_quant/min_time:5.000/manual_time        233 ms         44 ms         29 correct=203 frames=464 ms=6.497k wrong=261
BM_Mobilenet_v1_0_75_128_quant/min_time:5.000/manual_time        158 ms         38 ms         41 correct=287 frames=656 ms=6.148k wrong=369
BM_Mobilenet_v1_1_0_224/min_time:5.000/manual_time              2486 ms         95 ms          3 correct=21 frames=48 ms=7.437k wrong=27
BM_Mobilenet_v1_1_0_192/min_time:5.000/manual_time              1819 ms         88 ms          4 correct=36 frames=64 ms=7.239k wrong=28
BM_Mobilenet_v1_1_0_160/min_time:5.000/manual_time              1282 ms         74 ms          5 correct=40 frames=80 ms=6.364k wrong=40
BM_Mobilenet_v1_1_0_128/min_time:5.000/manual_time               834 ms         59 ms          7 correct=49 frames=112 ms=5.782k wrong=63
BM_Mobilenet_v1_0_75_224/min_time:5.000/manual_time             1800 ms         65 ms          4 correct=32 frames=64 ms=7.171k wrong=32
BM_Mobilenet_v1_0_75_192/min_time:5.000/manual_time             1329 ms         67 ms          5 correct=40 frames=80 ms=6.604k wrong=40
BM_Mobilenet_v1_0_75_160/min_time:5.000/manual_time              932 ms         55 ms          7 correct=49 frames=112 ms=6.463k wrong=63
BM_Mobilenet_v1_0_75_128/min_time:5.000/manual_time              609 ms         46 ms         10 correct=50 frames=160 ms=6.002k wrong=110
BM_Mobilenet_v2_1_4_224/min_time:5.000/manual_time              2027 ms        121 ms          3 correct=24 frames=48 ms=6.056k wrong=24
BM_Mobilenet_v2_1_3_224/min_time:5.000/manual_time              1857 ms        112 ms          3 correct=24 frames=48 ms=5.546k wrong=24
BM_Mobilenet_v2_1_0_224/min_time:5.000/manual_time              1359 ms         67 ms          5 correct=30 frames=80 ms=6.752k wrong=50
BM_Mobilenet_v2_1_0_192/min_time:5.000/manual_time              1006 ms         70 ms          6 correct=48 frames=96 ms=5.994k wrong=48
BM_Mobilenet_v2_1_0_160/min_time:5.000/manual_time               708 ms         58 ms          8 correct=56 frames=128 ms=5.605k wrong=72
BM_Mobilenet_v2_1_0_128/min_time:5.000/manual_time               468 ms         49 ms         11 correct=77 frames=176 ms=5.036k wrong=99
BM_Mobilenet_v2_1_0_96/min_time:5.000/manual_time                276 ms         39 ms         24 correct=144 frames=384 ms=6.42k wrong=240
BM_Mobilenet_v2_0_75_224/min_time:5.000/manual_time             1146 ms         57 ms          6 correct=42 frames=96 ms=6.829k wrong=54
BM_Mobilenet_v2_0_75_192/min_time:5.000/manual_time              840 ms         61 ms          7 correct=49 frames=112 ms=5.823k wrong=63
BM_Mobilenet_v2_0_75_160/min_time:5.000/manual_time              590 ms         51 ms         10 correct=80 frames=160 ms=5.822k wrong=80
BM_Mobilenet_v2_0_75_128/min_time:5.000/manual_time              382 ms         41 ms         18 correct=126 frames=288 ms=6.768k wrong=162
BM_Mobilenet_v2_0_75_96/min_time:5.000/manual_time               227 ms         37 ms         30 correct=60 frames=480 ms=6.499k wrong=420

4. Intel(R) Celeron(R) CPU N3450 @ 1.10GHz
w/o MKL
BM_Mobilenet_v1_1_0_224_quant/min_time:5.000/manual_time        6514 ms       1124 ms          1 correct=7 frames=16 ms=6.506k wrong=9
BM_Mobilenet_v1_1_0_192_quant/min_time:5.000/manual_time        5001 ms       1120 ms          1 correct=9 frames=16 ms=4.991k wrong=7
BM_Mobilenet_v1_1_0_160_quant/min_time:5.000/manual_time        3301 ms        607 ms          2 correct=12 frames=32 ms=6.589k wrong=20
BM_Mobilenet_v1_1_0_128_quant/min_time:5.000/manual_time        2198 ms        432 ms          3 correct=21 frames=48 ms=6.569k wrong=27
BM_Mobilenet_v1_0_75_224_quant/min_time:5.000/manual_time       3929 ms        449 ms          2 correct=16 frames=32 ms=7.841k wrong=16
BM_Mobilenet_v1_0_75_192_quant/min_time:5.000/manual_time       2945 ms        478 ms          2 correct=16 frames=32 ms=5.876k wrong=16
BM_Mobilenet_v1_0_75_160_quant/min_time:5.000/manual_time       2081 ms        348 ms          3 correct=21 frames=48 ms=6.218k wrong=27
BM_Mobilenet_v1_0_75_128_quant/min_time:5.000/manual_time       1369 ms        279 ms          4 correct=28 frames=64 ms=5.448k wrong=36
BM_Mobilenet_v1_1_0_224/min_time:5.000/manual_time              8103 ms        746 ms          1 correct=7 frames=16 ms=8.093k wrong=9
BM_Mobilenet_v1_1_0_192/min_time:5.000/manual_time              6147 ms        783 ms          1 correct=9 frames=16 ms=6.138k wrong=7
BM_Mobilenet_v1_1_0_160/min_time:5.000/manual_time              4208 ms        446 ms          2 correct=16 frames=32 ms=8.399k wrong=16
BM_Mobilenet_v1_1_0_128/min_time:5.000/manual_time              2874 ms        432 ms          2 correct=14 frames=32 ms=5.729k wrong=18
BM_Mobilenet_v1_0_75_224/min_time:5.000/manual_time             5630 ms        569 ms          1 correct=8 frames=16 ms=5.623k wrong=8
BM_Mobilenet_v1_0_75_192/min_time:5.000/manual_time             4053 ms        363 ms          2 correct=16 frames=32 ms=8.09k wrong=16
BM_Mobilenet_v1_0_75_160/min_time:5.000/manual_time             2903 ms        349 ms          2 correct=14 frames=32 ms=5.786k wrong=18
BM_Mobilenet_v1_0_75_128/min_time:5.000/manual_time             1850 ms        259 ms          3 correct=15 frames=48 ms=5.529k wrong=33
BM_Mobilenet_v2_1_4_224/min_time:5.000/manual_time              8482 ms       1003 ms          1 correct=8 frames=16 ms=8.472k wrong=8
BM_Mobilenet_v2_1_3_224/min_time:5.000/manual_time              7721 ms        925 ms          1 correct=8 frames=16 ms=7.714k wrong=8
BM_Mobilenet_v2_1_0_224/min_time:5.000/manual_time              5449 ms        730 ms          1 correct=6 frames=16 ms=5.44k wrong=10
BM_Mobilenet_v2_1_0_192/min_time:5.000/manual_time              3826 ms        433 ms          2 correct=16 frames=32 ms=7.637k wrong=16
BM_Mobilenet_v2_1_0_160/min_time:5.000/manual_time              2770 ms        424 ms          2 correct=14 frames=32 ms=5.519k wrong=18
BM_Mobilenet_v2_1_0_128/min_time:5.000/manual_time              1793 ms        310 ms          3 correct=21 frames=48 ms=5.354k wrong=27
BM_Mobilenet_v2_1_0_96/min_time:5.000/manual_time               1061 ms        226 ms          5 correct=30 frames=80 ms=5.264k wrong=50
BM_Mobilenet_v2_0_75_224/min_time:5.000/manual_time             4095 ms        364 ms          2 correct=14 frames=32 ms=8.173k wrong=18
BM_Mobilenet_v2_0_75_192/min_time:5.000/manual_time             3052 ms        388 ms          2 correct=14 frames=32 ms=6.089k wrong=18
BM_Mobilenet_v2_0_75_160/min_time:5.000/manual_time             2124 ms        286 ms          3 correct=24 frames=48 ms=6.349k wrong=24
BM_Mobilenet_v2_0_75_128/min_time:5.000/manual_time             1384 ms        234 ms          4 correct=28 frames=64 ms=5.504k wrong=36
BM_Mobilenet_v2_0_75_96/min_time:5.000/manual_time               834 ms        189 ms          6 correct=12 frames=96 ms=4.948k wrong=84
*/
