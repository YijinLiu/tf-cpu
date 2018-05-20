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
#include <glog/logging.h>

#include "simple_network.hpp"

DEFINE_int32(neurons, 30, "");
DEFINE_int32(epochs, 30, "");
DEFINE_int32(mini_batch_size, 10, "");
DEFINE_int32(num_samples_per_epoch, 60000, "");
DEFINE_double(weight_decay, 0.9999, "");
DEFINE_double(learning_rate, 0.5, "");
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
    google::InitGoogleLogging(argv[0]);
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
