#include "test_video.hpp"

#include <stdlib.h>

#include <string>

#include <glog/logging.h>

extern "C" {

#include <libavdevice/avdevice.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libavutil/time.h>

}  // extern "C"

namespace {

#ifndef ARRAYSIZE
#define ARRAYSIZE(buf) sizeof(buf)/sizeof(buf[0])
#endif

std::string Sprintf(const char* format, ...) {
    char buf[1000];
    va_list ap;
    va_start(ap, format);
    vsnprintf(buf, ARRAYSIZE(buf), format, ap);
    va_end(ap);
    return buf;
}

std::string FfmpegErrStr(int rc) {
    char err_buf[200];
    if (av_strerror(rc, err_buf, ARRAYSIZE(err_buf)) == 0) {
        return Sprintf("%s(%d)", err_buf, rc);
    }
    return Sprintf("(%d)", rc);
}

}  // namespace

void InitFfmpeg(int log_level) {
    setenv("AV_LOG_FORCE_COLOR", "1", 0);
    avcodec_register_all();
    av_register_all();
    avfilter_register_all();
    avdevice_register_all();
    avformat_network_init();
    av_log_set_level(log_level);
}

TestVideo::TestVideo(enum AVPixelFormat pix_fmt, uint32_t width, uint32_t height)
    : pix_fmt_(pix_fmt), width_(width), height_(height) {}

TestVideo::~TestVideo() {
    avfilter_graph_free(&graph_);
    av_packet_free(&pkt_);
    avcodec_free_context(&dec_ctx_);
    avformat_close_input(&fmt_ctx_);
}

bool TestVideo::Init(const std::string& file, const char* format, bool keep_ar) {
    // Open input.
    AVInputFormat* input_format = nullptr;
    if (format != nullptr) {
        input_format = av_find_input_format(format);
        if (input_format == nullptr) {
            LOG(ERROR) << "Cannot find input format " << format;
            return false;
        }
    }
    AVDictionary* options = nullptr;
    int rc = avformat_open_input(&fmt_ctx_, file.c_str(), input_format, &options);
    if (options != nullptr) {
        char* buffer = nullptr;
        av_dict_get_string(options, &buffer, '=', ' ');
        LOG(WARNING) << "Options not used: " << buffer;
        free(buffer);
        av_dict_free(&options);
    }
    if (rc != 0) {
        LOG(ERROR) << "avformat_open_input(" << file << ") failed: " << FfmpegErrStr(rc);
        return false;
    }

    // Find video stream.
    const int nb_streams = fmt_ctx_->nb_streams;
    AVDictionary** options_array = new AVDictionary*[nb_streams];
    for (int i = 0; i < nb_streams; ++i) {
        options_array[i] = nullptr;
        av_dict_set(options_array + i, "threads", "1", 0);
        av_dict_set(options_array + i, "ec", "0", 0);
        av_dict_set(options_array + i, "err_detect", "explode", 0);
    }
    rc = avformat_find_stream_info(fmt_ctx_, options_array);
    for (int i = 0; i < nb_streams; ++i) av_dict_free(options_array + i);
    delete[] options_array;
    for (int i = 0; i < fmt_ctx_->nb_streams; ++i) {
        AVStream* stream = fmt_ctx_->streams[i];
        if (stream->codecpar->codec_id == AV_CODEC_ID_PROBE) {
            LOG(WARNING) << "Failed to probe codec for input stream " << stream->index;
            continue;
        }
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && video_ == nullptr) {
            video_ = stream;
        } else {
            LOG(INFO) << "Ignoring stream " << stream->index << " with type "
                << av_get_media_type_string(stream->codecpar->codec_type);
        }
    }
    if (video_ == nullptr) {
        LOG(ERROR) << "Failed to find video stream!";
        return false;
    }

    // Open decoder.
    AVCodec* codec = avcodec_find_decoder(video_->codecpar->codec_id);
    if (codec == nullptr) {
        LOG(ERROR) << "Unsupported video codec " << avcodec_get_name(video_->codecpar->codec_id);
        return false;
    }
    dec_ctx_ = avcodec_alloc_context3(codec);
    rc = avcodec_parameters_to_context(dec_ctx_, video_->codecpar);
    if (rc < 0) {
        LOG(ERROR) << "avcodec_parameters_to_context failed: " << FfmpegErrStr(rc);
        return false;
    }
    // Don't use multiple threads, which will actually increase CPU usage.
    dec_ctx_->thread_count = 1;
    dec_ctx_->error_concealment = 0;
    // Quit decoding if there are errors, which is usually caused by packet loss.
    // This way, we won't have these corrupted frames that only mess up motion detection.
    dec_ctx_->err_recognition = AV_EF_EXPLODE;
    rc = avcodec_open2(dec_ctx_, codec, &options);
    av_dict_free(&options);
    if (rc < 0) {
        LOG(INFO) << "Could not open video codec " << FfmpegErrStr(rc);
        return false;
    }
    rc = avcodec_parameters_from_context(video_->codecpar, dec_ctx_);
    if (rc < 0) {
        LOG(INFO) << "avcodec_parameters_from_context failed: " << FfmpegErrStr(rc);
        return false;
    }
    pkt_ = av_packet_alloc();

    // Create filter graph.
    graph_ = avfilter_graph_alloc();
    if (graph_ == nullptr) {
        LOG(ERROR) << "avfilter_graph_alloc failed!";
        return false;
    }
    av_opt_set_int(graph_, "threads", 1, 0);
    // Create "buffer" filter.
    const enum AVPixelFormat pix_fmt = static_cast<enum AVPixelFormat>(video_->codecpar->format);
    const uint32_t width = video_->codecpar->width;
    const uint32_t height = video_->codecpar->height;
    if (width_ <= 0 && height_ <= 0) {
        width_ = width;
        height_ = height;
    } else if (width_ <= 0) {
        // Keep aspect ratio.
        width_ = width * height_ / height;
    } else if (height_ <= 0) {
        // Keep aspect ratio.
        height_ = height * width_ / width;
    }
    AVFilter* buffersrc  = avfilter_get_by_name("buffer");
    const std::string buffersrc_args = Sprintf(
        "video_size=%dx%d:pix_fmt=%s:time_base=1/90000", width, height,
        av_get_pix_fmt_name(pix_fmt));
    rc = avfilter_graph_create_filter(&in_, buffersrc, "in", buffersrc_args.c_str(), nullptr, graph_);
    if (rc < 0) {
        LOG(ERROR) << "avfilter_graph_create_filter(buffer=" << buffersrc_args
            << ") failed: " << FfmpegErrStr(rc);
        return false;
    }
    // Create "buffersink" filter.
    AVFilter* buffersink = avfilter_get_by_name("buffersink");
    rc = avfilter_graph_create_filter(&out_, buffersink, "out", nullptr, nullptr, graph_);
    if (rc < 0) {
        LOG(ERROR) << "avfilter_graph_create_filter(buffersink) failed: " << FfmpegErrStr(rc);
        return false;
    }
    enum AVPixelFormat pix_fmts[] = { pix_fmt_, AV_PIX_FMT_NONE };
    rc = av_opt_set_int_list(out_, "pix_fmts", pix_fmts, AV_PIX_FMT_NONE, AV_OPT_SEARCH_CHILDREN);
    if (rc < 0) {
        LOG(ERROR) << "av_opt_set_int_list pix_fmts failed: " << FfmpegErrStr(rc);
        return false;
    }
    // Generate filter string.
    std::string filter_str;
#define ADD_FILTER(name, format, args...) \
    do { \
        if (!filter_str.empty()) filter_str += ','; \
        filter_str += Sprintf("%s=" format, name, args); \
    } while (false)
    if (width_ != width || height_ != height) {
        // Add margins if needed.
        if (keep_ar &&
            fabs((double)width / height - (double)width_ / height_) > 0.01) {
            int orx = 0, ory = 0, orw = width_, orh = height_;
            if (width * height_ > width_ * height) {
                // Add vertical margins.
                orh = width_ * height / width;
                ory = (height_ - orh) / 2;
            } else {
                // Add horizontal margins.
                orw = height_ * width / height;
                orx = (width_ - orw) / 2;
            }
            ADD_FILTER("scale", "w=%d:h=%d", orw, orh);
            ADD_FILTER("pad", "%d:%d:%d:%d:black", width_, height_, orx, ory);
        } else {
            ADD_FILTER("scale", "w=%d:h=%d", width_, height_);
        }
    }
    if (pix_fmt != pix_fmt_) {
        ADD_FILTER("format", "%s", av_get_pix_fmt_name(pix_fmt_));
    }
#undef ADD_FILTER
    VLOG(1) << "Using filter '" << filter_str << "'...";
    // Create filter chain.
    AVFilterInOut* outputs = avfilter_inout_alloc();
    outputs->name = av_strdup("in");
    outputs->filter_ctx = in_;
    outputs->pad_idx = 0;
    outputs->next = nullptr;
    AVFilterInOut* inputs  = avfilter_inout_alloc();
    inputs->name = av_strdup("out");
    inputs->filter_ctx = out_;
    inputs->pad_idx = 0;
    inputs->next = nullptr;
    rc = avfilter_graph_parse_ptr(graph_, filter_str.c_str(), &inputs, &outputs, nullptr);
    avfilter_inout_free(&inputs);
    avfilter_inout_free(&outputs);
    if (rc < 0) {
        LOG(ERROR) << "avfilter_graph_parse_ptr(" << filter_str << ") failed: " << FfmpegErrStr(rc);
        return false;
    }
    rc = avfilter_graph_config(graph_, nullptr);
    if (rc < 0) {
        LOG(ERROR) << "avfilter_graph_config failed: " << FfmpegErrStr(rc);
        return false;
    }

    return true;
}

AVFrame* TestVideo::NextFrame() {
    // Read packet if needed.
    while (need_pkt_) {
        if (!ReadPacket()) return nullptr;
        const int rc = avcodec_send_packet(dec_ctx_, pkt_);
        if (rc < 0 && rc != AVERROR_EOF) {
            LOG(WARNING) << "avcodec_send_packet failed: " << FfmpegErrStr(rc);
            continue;
        }
        need_pkt_ = false;
    }

    // Decode.
    AVFrame* decoded = av_frame_alloc();
    int rc = avcodec_receive_frame(dec_ctx_, decoded);
    if (rc < 0) {
        if (rc == AVERROR_EOF) return nullptr;
        if (rc != AVERROR(EAGAIN)) {
            LOG(WARNING) << "avcodec_receive_frame failed: " << FfmpegErrStr(rc);
        }
        av_frame_free(&decoded);
        need_pkt_ = true;
        return NextFrame();
    }

    // Convert.
    rc = av_buffersrc_add_frame_flags(
        in_, decoded, AV_BUFFERSRC_FLAG_KEEP_REF | AV_BUFFERSRC_FLAG_PUSH);
    av_frame_free(&decoded);
    if (rc < 0) {
        LOG(ERROR) << "av_buffersrc_add_frame_flags failed: " << FfmpegErrStr(rc);
        return NextFrame();
    }
    AVFrame* frame = av_frame_alloc();
    rc = av_buffersink_get_frame_flags(out_, frame, AV_BUFFERSINK_FLAG_NO_REQUEST);
    if (rc < 0) {
        LOG(ERROR) << "av_buffersink_get_frame_flags failed: " << FfmpegErrStr(rc);
        av_frame_free(&frame);
        return NextFrame();
    }
    return frame;
}

bool TestVideo::ReadPacket() {
    av_packet_unref(pkt_);
    const int rc = av_read_frame(fmt_ctx_, pkt_);
    if (rc == AVERROR(EAGAIN)) {
        av_usleep(100);
    } else if (rc < 0) {
        // EOF
        return false;
    } else if ((pkt_->flags & AV_PKT_FLAG_CORRUPT) != 0) {
        LOG(WARNING) << "Read corrupted packet.";
    } else if (pkt_->stream_index == video_->index) {
        return true;
    }
    return ReadPacket();
}
