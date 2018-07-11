// TODO(in tensorflow):
// 1. Implement SigmoidCrossEntropyWithLogits and its gradient.
// 2. Implement SoftmaxLogLikelihoodWithLogits and its gradient.

#include "simple_network.hpp"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include <iomanip>
#include <limits>

#include <tensorflow/cc/framework/gradients.h>
#include <tensorflow/core/graph/mkl_layout_pass.h>

#include "utils.hpp"

#define INPUTS "inputs"
#define LABELS "labels"
#define LOSS "loss"
#define GRAD_SUFFIX "_grad"

namespace {

inline std::string LayerW(int l) { return Sprintf("l%d_w", l); }

inline std::string LayerB(int l) { return Sprintf("l%d_b", l); }

inline std::string LayerZ(int l) { return Sprintf("l%d_z", l); }

inline std::string LayerA(int l) { return Sprintf("l%d_a", l); }

tf::SessionOptions SessionOptions() {
    tensorflow::SessionOptions sess_opts;
    sess_opts.config.mutable_device_count()->insert({"CPU", 1});
    sess_opts.config.set_intra_op_parallelism_threads(1);
    sess_opts.config.set_inter_op_parallelism_threads(1);
    sess_opts.config.set_allow_soft_placement(1);
    sess_opts.config.set_isolate_session_state(1);
    return sess_opts;
}

}  // namespace

SimpleNetwork::SimpleNetwork(const std::vector<Layer>& layers, int mini_batch_size)
    : layers_(layers), mini_batch_size_(mini_batch_size),
      scope_(tf::Scope::NewRootScope().ExitOnError()), session_(scope_, SessionOptions()),
      inputs_(scope_.WithOpName(INPUTS), tf::DT_FLOAT,
              tf::ops::Placeholder::Shape({mini_batch_size_, layers[0].num_neurons})),
      labels_(scope_.WithOpName(LABELS), tf::DT_INT32,
              tf::ops::Placeholder::Shape({mini_batch_size_})) {
    // Check layers.
    CHECK_GE(layers.size(), 2);

    const auto& input_layer = layers.front();
    if (input_layer.activation != ActivationFunc::Identity) {
        LOG(FATAL)
            << "Input layer's activation function needs to be identity, found "
            << static_cast<int>(input_layer.activation);
    }
    input_size_ = input_layer.num_neurons;

    const auto& output_layer = layers.back();
    switch (output_layer.activation) {
        case ActivationFunc::Sigmoid:
        case ActivationFunc::SoftMax:
            break;
        default:
            LOG(FATAL)
                << "Output layer's activation function needs to be sigmoid or softmax, found "
                << static_cast<int>(output_layer.activation);
    }
    output_classes_ = output_layer.num_neurons;
}

void SimpleNetwork::Train(
    const std::vector<Case>& training_data, size_t num_samples_per_epoch, size_t epochs,
    float weight_decay, float learning_rate, const std::vector<Case>* testing_data) {
    // Add layers.
    std::vector<tf::Output> inits;
    std::vector<std::string> param_names;
    std::vector<tf::Output> params;
    tf::Output z;
    tf::Output a = tf::ops::StopGradient(scope_, inputs_);
    tf::Output labels = tf::ops::StopGradient(scope_, labels_);
    tf::Output loss;
    for (int i = 1; i < layers_.size(); i++) {
        const int rows = layers_[i-1].num_neurons;
        const int cols = layers_[i].num_neurons;
        // Init weight.
        const std::string weight_name = LayerW(i);
        auto weight = tf::ops::Variable(scope_.WithOpName(weight_name), {rows, cols}, tf::DT_FLOAT);
        param_names.push_back(weight_name);
        params.push_back(weight);
        inits.push_back(tf::ops::Assign(scope_, weight, tf::ops::Div(
            scope_, tf::ops::RandomNormal(scope_, {rows, cols}, tf::DT_FLOAT), ::sqrtf(rows))));
        CHECK(scope_.ok()) << scope_.status();
        // Init bias.
        const std::string bias_name = LayerB(i);
        auto bias = tf::ops::Variable(scope_.WithOpName(bias_name), {cols}, tf::DT_FLOAT);
        param_names.push_back(bias_name);
        params.push_back(bias);
        inits.push_back(tf::ops::Assign(
            scope_, bias, tf::ops::RandomNormal(scope_, {cols}, tf::DT_FLOAT)));
        // FC node.
        z = tf::ops::BiasAdd(
            scope_.WithOpName(LayerZ(i)), tf::ops::MatMul(scope_, a, weight), bias);
        // Activation node.
        switch (layers_[i].activation) {
            case ActivationFunc::Identity:
                a = z;
                break;
            case ActivationFunc::ReLU:
                a = tf::ops::Relu(scope_.WithOpName(LayerA(i)), z);
                break;
            case ActivationFunc::Sigmoid:
                if (i == layers_.size() - 1) {
                    auto output = tf::ops::SigmoidWithCrossEntropyLoss(
                        scope_.WithOpName(LayerA(i)), z, labels);
                    a = output.sigmoid;
                    loss = output.loss;
                } else {
                    a = tf::ops::Sigmoid(scope_.WithOpName(LayerA(i)), z);
                }
                break;
            case ActivationFunc::SoftMax:
                if (i == layers_.size() - 1) {
                    auto output = tf::ops::SoftmaxWithLogLikelihoodLoss(
                        scope_.WithOpName(LayerA(i)), z, labels);
                    a = output.softmax;
                    loss = output.loss;
                } else {
                    a = tf::ops::Softmax(scope_.WithOpName(LayerA(i)), z);
                }
                break;
            default:
                LOG(FATAL)
                    << "Unknown activation function: " << static_cast<int>(layers_[i].activation);
        }
    }

    // Accuracy node.
    auto bool_corrects = tf::ops::Equal(
        scope_, tf::ops::ArgMax(scope_, a, 1, tf::ops::ArgMax::OutputType(tf::DT_INT32)), labels_);
    corrects_ = tf::ops::Sum(scope_, tf::ops::Cast(scope_, bool_corrects, tf::DT_INT32), 0);
    std::vector<tf::Output> objectives;
    objectives.push_back(corrects_);

    // Apply gradients.
    std::vector<tf::Output> param_grads;
    TF_CHECK_OK(tf::AddSymbolicGradients(scope_, {loss}, params, &param_grads));
    for (int i = 0; i < params.size(); i++) {
        if (weight_decay != 1.f) {
            objectives.push_back(tf::ops::Assign(
                scope_, params[i], tf::ops::Multiply(scope_, params[i], weight_decay)));
        }
        objectives.push_back(tf::ops::ApplyGradientDescent(
            scope_.WithOpName(param_names[i] + GRAD_SUFFIX), params[i], learning_rate,
            param_grads[i]));
    }

#ifdef INTEL_MKL
    // TODO: This is not doing anything for now. Figure out why.
    std::unique_ptr<tf::Graph> graph(scope_.graph());
    if (tf::RunMklLayoutRewritePass(&graph)) {
        LOG(INFO) << "Optimized the graph using MKL.";
    }
    graph.release();
#endif

    // Init parameters.
    std::vector<tf::Tensor> outputs;
    const auto status = session_.Run(inits, &outputs);
    CHECK(status.ok()) << status.ToString();

    // Train.
    tf::Tensor batch_inputs(tf::DT_FLOAT, {mini_batch_size_, input_size_});
    float* raw_batch_inputs = batch_inputs.flat<float>().data();
    tf::Tensor batch_labels(tf::DT_INT32, {mini_batch_size_});
    int32_t* raw_batch_labels = batch_labels.flat<int32_t>().data();
    size_t n = std::min(training_data.size(), num_samples_per_epoch);
    std::vector<int> indices(training_data.size());
    for (int i = 0; i < training_data.size(); i++) indices[i] = i;
    srand48(time(NULL));
    for (int e = 0; e < epochs; e++) {
        // Random shuffle.
        for (int i = 0; i < n; i++) {
            const size_t step = lrand48() % (training_data.size() - i);
            if (step > 0) std::swap(indices[i], indices[i + step]);
        }
        int32_t total = 0, corrects = 0;
        for (int k = 0; k <= n - mini_batch_size_; k += mini_batch_size_) {
            for (int i = 0; i < mini_batch_size_; i++) {
                const auto& c = training_data[indices[k+i]];
                memcpy(raw_batch_inputs + i * input_size_, c.first.data(),
                       input_size_ * sizeof(float));
                raw_batch_labels[i] = c.second;
            }
            const auto status = session_.Run(
                {{inputs_, batch_inputs}, {labels_, batch_labels}}, objectives, &outputs);
            CHECK(status.ok()) << status.ToString();
            total += mini_batch_size_;
            corrects += outputs[0].scalar<int32_t>()(0);
        }
        VLOG(0) << "Epoch " << e + 1 << " training accuracy: " << std::setprecision(4)
            << (float)corrects / total << "(" << corrects << "/" << total << ").";
        if (testing_data) {
            const auto result = Evaluate(*testing_data);
            LOG(INFO) << "Epoch " << e + 1 << " testing accuracy: " << std::setprecision(4)
                << (float)result.first / result.second
                << "(" << result.first << "/" << result.second << ").";
        }
    }
}

std::pair<int32_t, int32_t> SimpleNetwork::Evaluate(const std::vector<Case>& testing_data) {
    tf::Tensor batch_inputs(tf::DT_FLOAT, {mini_batch_size_, input_size_});
    float* raw_batch_inputs = batch_inputs.flat<float>().data();
    tf::Tensor batch_labels(tf::DT_INT32, {mini_batch_size_});
    int32_t* raw_batch_labels = batch_labels.flat<int32_t>().data();
    std::vector<tf::Output> objectives;
    objectives.push_back(corrects_);
    std::vector<tf::Tensor> outputs;

    const int n = testing_data.size();
    int32_t total = 0, corrects = 0;
    for (int k = 0; k <= n - mini_batch_size_; k += mini_batch_size_) {
        for (int i = 0; i < mini_batch_size_; i++) {
            const auto& c = testing_data[k+i];
            memcpy(raw_batch_inputs + i * input_size_, c.first.data(),
                   input_size_ * sizeof(float));
            raw_batch_labels[i] = c.second;
        }
        session_.Run({{inputs_, batch_inputs}, {labels_, batch_labels}}, objectives, &outputs);
        total += mini_batch_size_;
        corrects += outputs[0].scalar<int32_t>()(0);
    }
    return std::make_pair(corrects, total);
}
