#ifndef VIDEO_ENCODER_HPP_
#define VIDEO_ENCODER_HPP_

#include <string>

#include "utils.hpp"

class VideoEncoder {
  public:
    VideoEncoder();
    ~VideoEncoder();

    bool Init(enum AVPixelFormat pix_fmt, int width, int height, AVRational time_base,
              const std::string& output_file);
    bool EncodeAVFrame(AVFrame* frame);
    void Close();

  private:
    bool DoEncode(AVFrame* frame);

    AVFormatContext* fmt_ctx_ = nullptr;
    AVStream* video_ = nullptr;
    AVCodecContext* enc_ctx_ = nullptr;
    AVFilterGraph* graph_ = nullptr;
    AVFilterContext* in_ = nullptr;
    AVFilterContext* out_ = nullptr;
};

#endif  // VIDEO_ENCODER_HPP_
