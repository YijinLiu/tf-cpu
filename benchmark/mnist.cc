#include <inttypes.h>
#include <libgen.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define _BSD_SOURCE
#include <endian.h>

#include <ios>
#include <memory>
#include <string>
#include <vector>

#include <gflags/gflags.h>

#include "simple_network.hpp"

DEFINE_int32(neurons, 30, "");
DEFINE_int32(epochs, 30, "");
DEFINE_int32(mini_batch_size, 10, "");
DEFINE_int32(num_samples_per_epoch, 60000, "");
DEFINE_double(weight_decay, 1.0, "");
DEFINE_double(learning_rate, 0.01, "");
DEFINE_string(data_dir, "", "");

namespace {

#define IDX_DATA_TYPE_U8 0x8
#define IDX_DATA_TYPE_S8 0x9
#define IDX_DATA_TYPE_I16 0xb
#define IDX_DATA_TYPE_I32 0xc
#define IDX_DATA_TYPE_F32 0xd
#define IDX_DATA_TYPE_F64 0xe

uint32_t ReadIDXFile(FILE* fh, std::vector<uint32_t>& dimensions) {
    uint32_t magic;
    size_t bytes = fread(&magic, 1, 4, fh);
    CHECK_EQ(bytes, 4) << "Failed to read magic number!";
    magic = be32toh(magic);
    CHECK((magic&0xffff0000) == 0) << "Invalid magic number: " << std::hex << magic;
    uint32_t n = magic & 0xff;
    dimensions.resize(n);
    for (int i = 0; i < n; i++) {
        uint32_t dimension;
        size_t bytes = fread(&dimension, 1, 4, fh);
        CHECK_EQ(bytes, 4) << "Failed to read dimension #" << i;
        dimensions[i] = be32toh(dimension);
    }
    return magic >> 8;
}

std::vector<SimpleNetwork::Case> LoadMNISTData(std::string data_dir, const std::string& name) {
    if (data_dir.empty()) {
        char path[1000];
        ssize_t rc = readlink("/proc/self/exe", path, sizeof(path));
        CHECK_GT(rc, 0) << "Failed to get executable path!";
        dirname(dirname(dirname(path)));
        strncat(path, "/mnist_data", sizeof(path) - strlen(path) - 1);
        data_dir = path;
    }
    const std::string images_file = data_dir + "/" + name + "-images-idx3-ubyte";
    // Open images file.
    FILE* images_fh = CHECK_NOTNULL(fopen(images_file.c_str(), "rb"));
    std::vector<uint32_t> image_dims;
    const uint32_t image_data_type = ReadIDXFile(images_fh, image_dims);
    CHECK_EQ(IDX_DATA_TYPE_U8, image_data_type) << "Invalid image data type: " << image_data_type;
    CHECK_EQ(3, image_dims.size()) << "Invalid image #dims: " << image_dims.size();
    const uint32_t num_images = image_dims[0];
    const uint32_t image_size = image_dims[1] * image_dims[2];

    // Open labels file.
    const std::string labels_file = data_dir + "/" + name + "-labels-idx1-ubyte";
    FILE* labels_fh = CHECK_NOTNULL(fopen(labels_file.c_str(), "rb"));
    std::vector<uint32_t> label_dims;
    const uint32_t label_data_type = ReadIDXFile(labels_fh, label_dims);
    CHECK_EQ(IDX_DATA_TYPE_U8, label_data_type) << "Invalid label data type: " << label_data_type;
    CHECK_EQ(1, label_dims.size()) << "Invalid label #dims: " << label_dims.size();
    const uint32_t num_labels = label_dims[0];
    CHECK_EQ(num_images, num_labels) << "#images != #labels: " << num_images << "!=" << num_labels;

    std::vector<SimpleNetwork::Case> results(num_images);
    std::unique_ptr<uint8_t[]> image_data(new uint8_t[image_size]);
    for (int i = 0; i < num_images; i++) {
        size_t bytes = fread(image_data.get(), 1, image_size, images_fh);
        CHECK_EQ(bytes, image_size) << "Failed to read image #" << i;
        auto& image = results[i].first;
        image.resize(image_size);
        for (int j = 0; j < image_size; j++) image(j) = image_data[j] / 256.f;
        uint8_t label;
        bytes = fread(&label, 1, 1, labels_fh);
        CHECK_EQ(bytes, 1) << "Failed to read label #" << i;
        results[i].second = label;
    }

    fclose(images_fh);
    fclose(labels_fh);
    return results;
}

}  // namespace

int main(int argc, char* argv[]) {
    google::SetCommandLineOption("v", "-1");
    google::ParseCommandLineFlags(&argc, &argv, true);
    LOG(INFO) << "Loading MNIST data into memory ...";
    const auto training_data = LoadMNISTData(FLAGS_data_dir, "train");
    const auto testing_data = LoadMNISTData(FLAGS_data_dir, "t10k");
    LOG(INFO) << "Training using MNIST data ...";
    const int image_size = training_data[0].first.size();
    std::vector<SimpleNetwork::Layer> layers;
    layers.push_back({image_size, SimpleNetwork::ActivationFunc::Identity});
    layers.push_back({FLAGS_neurons, SimpleNetwork::ActivationFunc::Sigmoid});
    layers.push_back({10, SimpleNetwork::ActivationFunc::SoftMax});
    SimpleNetwork network(layers, FLAGS_mini_batch_size);
    network.Train(training_data, FLAGS_num_samples_per_epoch, FLAGS_epochs, FLAGS_weight_decay,
                  FLAGS_learning_rate, &testing_data);
}

/*
2018-07-12 05:46:37.117916: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 1 testing accuracy: 0.9337(9337/10000).
2018-07-12 05:46:37.693736: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 2 testing accuracy: 0.9458(9458/10000).
2018-07-12 05:46:38.195392: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 3 testing accuracy: 0.9546(9546/10000).
2018-07-12 05:46:38.704860: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 4 testing accuracy: 0.9572(9572/10000).
2018-07-12 05:46:39.209291: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 5 testing accuracy: 0.9574(9574/10000).
2018-07-12 05:46:39.726780: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 6 testing accuracy: 0.96(9600/10000).
2018-07-12 05:46:40.230298: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 7 testing accuracy: 0.961(9610/10000).
2018-07-12 05:46:40.735489: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 8 testing accuracy: 0.9646(9646/10000).
2018-07-12 05:46:41.240680: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 9 testing accuracy: 0.9658(9658/10000).
2018-07-12 05:46:41.780601: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 10 testing accuracy: 0.9654(9654/10000).
2018-07-12 05:46:42.286129: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 11 testing accuracy: 0.966(9660/10000).
2018-07-12 05:46:42.793442: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 12 testing accuracy: 0.9646(9646/10000).
2018-07-12 05:46:43.299229: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 13 testing accuracy: 0.9671(9671/10000).
2018-07-12 05:46:43.848350: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 14 testing accuracy: 0.965(9650/10000).
2018-07-12 05:46:44.349775: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 15 testing accuracy: 0.9656(9656/10000).
2018-07-12 05:46:44.853401: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 16 testing accuracy: 0.9667(9667/10000).
2018-07-12 05:46:45.359143: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 17 testing accuracy: 0.9676(9676/10000).
2018-07-12 05:46:45.878410: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 18 testing accuracy: 0.9665(9665/10000).
2018-07-12 05:46:46.381842: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 19 testing accuracy: 0.9679(9679/10000).
2018-07-12 05:46:46.887141: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 20 testing accuracy: 0.9644(9644/10000).
2018-07-12 05:46:47.391725: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 21 testing accuracy: 0.964(9640/10000).
2018-07-12 05:46:47.913578: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 22 testing accuracy: 0.9667(9667/10000).
2018-07-12 05:46:48.430757: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 23 testing accuracy: 0.9649(9649/10000).
2018-07-12 05:46:48.947995: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 24 testing accuracy: 0.9661(9661/10000).
2018-07-12 05:46:49.462165: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 25 testing accuracy: 0.9654(9654/10000).
2018-07-12 05:46:49.988273: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 26 testing accuracy: 0.9658(9658/10000).
2018-07-12 05:46:50.490390: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 27 testing accuracy: 0.9653(9653/10000).
2018-07-12 05:46:50.994772: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 28 testing accuracy: 0.9675(9675/10000).
2018-07-12 05:46:51.497389: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 29 testing accuracy: 0.9667(9667/10000).
2018-07-12 05:46:52.011331: I /home/chao/projects/tf-cpu/benchmark/simple_network.cc:210] Epoch 30 testing accuracy: 0.9657(9657/10000).
*/
