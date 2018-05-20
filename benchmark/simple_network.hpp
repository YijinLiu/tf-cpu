#ifndef SIMPLE_NETWORK_HPP_
#define SIMPLE_NETWORK_HPP_

#include <string>
#include <utility>
#include <vector>

#include <Eigen/Dense>

#include <tensorflow/cc/client/client_session.h>
#include <tensorflow/cc/ops/standard_ops.h>

namespace tf = tensorflow;

// A simple neural network implementation using only full-connected neurals.
class SimpleNetwork {
  public:
    enum class ActivationFunc {
        Identity,
        ReLU,
        Sigmoid,
        SoftMax
    };

    struct Layer {
        int num_neurons;
        ActivationFunc activation;
    };

    typedef std::pair<Eigen::RowVectorXf, int> Case;

    SimpleNetwork(const std::vector<Layer>& layers, int mini_batch_size);

    void Train(
        const std::vector<Case>& training_data, size_t num_samples_per_epoch, size_t epochs,
        float weight_decay, float learning_rate, const std::vector<Case>* testing_data);

    std::pair<int32_t, int32_t> Evaluate(const std::vector<Case>& testing_data);

  private:
    const std::vector<Layer> layers_;
    const int mini_batch_size_;
    int input_size_;
    int output_classes_;
    tf::Scope scope_;
    tf::ClientSession session_;
    tf::ops::Placeholder inputs_;
    tf::ops::Placeholder labels_;
    tf::Output corrects_;
};

#endif  // SIMPLE_NETWORK_HPP_
