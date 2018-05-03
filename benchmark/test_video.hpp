#ifndef TEST_VIDEO_HPP_
#define TEST_VIDEO_HPP_

#include <string>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/avfiltergraph.h>
#include <libavformat/avformat.h>
}  // extern "C"

class TestVideo {
  public:
    TestVideo(enum AVPixelFormat pix_fmt, uint32_t width, uint32_t height);
    ~TestVideo();

    bool Init(const std::string& file, const char* format, bool keep_ar);

    // Caller takes ownership of the returned frame and must call av_frame_free on it.
    AVFrame* NextFrame();

    uint32_t width() const { return width_; }
    uint32_t height() const { return height_; }

  private:
    bool ReadPacket();

    const enum AVPixelFormat pix_fmt_;
    uint32_t width_, height_;
    AVFormatContext* fmt_ctx_ = nullptr;
    AVStream* video_ = nullptr;
    AVCodecContext* dec_ctx_ = nullptr;
    AVPacket* pkt_ = nullptr;
    bool need_pkt_ = true;
    AVFilterGraph* graph_ = nullptr;
    AVFilterContext* in_ = nullptr;
    AVFilterContext* out_ = nullptr;
};

void InitFfmpeg(int log_level);

#endif  // TEST_VIDEO_HPP_
