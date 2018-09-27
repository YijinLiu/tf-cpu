#include "video_encoder.hpp"

#include <glog/logging.h>

VideoEncoder::VideoEncoder() {
}

VideoEncoder::~VideoEncoder() {
    Close();
}

namespace {

AVRational get_supported_framerate(const AVCodec* codec, const AVRational hint) {
    if (codec->supported_framerates == NULL) return hint;
    const int index = av_find_nearest_q_idx(hint, codec->supported_framerates);
    return codec->supported_framerates[index];
}

}  // namespace

bool VideoEncoder::Init(enum AVPixelFormat pix_fmt, int width, int height, AVRational time_base,
                        const std::string& output_file) {
    // Create AVFormatContext.
    int rc = avformat_alloc_output_context2(&fmt_ctx_, nullptr, "matroska", nullptr);
    if (rc < 0) {
        LOG(ERROR) << "avformat_alloc_output_context2 failed: " << FfmpegErrStr(rc);
        return false;
    }
    // 0.5s.
    fmt_ctx_->max_delay = 500000;
    fmt_ctx_->pb = NULL;
    fmt_ctx_->flags |= AVFMT_FLAG_DISCARD_CORRUPT;

    // Find encoder and create stream.
    AVCodec* video_codec = avcodec_find_encoder_by_name("libx264");
    if (video_codec == nullptr) {
        LOG(ERROR) << "Failed to find encoder libx264!";
        return false;
    }
    fmt_ctx_->oformat->video_codec = video_codec->id;
    video_ = avformat_new_stream(fmt_ctx_, video_codec);
    if (video_ == nullptr) {
        LOG(ERROR) << "Failed to allocate stream!";
        return false;
    }

    // Open encoder.
    enc_ctx_ = avcodec_alloc_context3(video_codec);
    if (enc_ctx_ == nullptr) {
        LOG(ERROR) << "avcodec_alloc_context3 failed for x264!";
        return false;
    }
    enc_ctx_->codec_type = AVMEDIA_TYPE_VIDEO;
    if ((fmt_ctx_->oformat->flags & AVFMT_GLOBALHEADER) != 0) {
        enc_ctx_->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }
    enc_ctx_->pix_fmt = AV_PIX_FMT_YUV420P;
    enc_ctx_->width = width;
    enc_ctx_->height = height;
    enc_ctx_->strict_std_compliance = FF_COMPLIANCE_STRICT;
    enc_ctx_->slices = 1;
    enc_ctx_->has_b_frames = 0;
    enc_ctx_->max_b_frames = 0;
    enc_ctx_->qmin = 0;
    enc_ctx_->qmax = 20;
    enc_ctx_->thread_count = 1;
    enc_ctx_->refs = 1;
    enc_ctx_->gop_size = 100;

    enc_ctx_->time_base = video_->time_base = time_base;

    AVDictionary* opts = nullptr;
    av_dict_set(&opts, "preset", "fast", 0);
    av_dict_set(&opts, "profile", "baseline", 0);
    av_dict_set(&opts, "qp", "20", 0);
    rc = avcodec_open2(enc_ctx_, video_codec, &opts);
    av_dict_free(&opts);
    if (rc < 0) {
        LOG(ERROR) << "Failed to open encoder: " << FfmpegErrStr(rc);
        return false;
    }
    rc = avcodec_parameters_from_context(video_->codecpar, enc_ctx_);
    if (rc < 0) {
        LOG(ERROR) << "avcodec_parameters_from_context failed: " << FfmpegErrStr(rc);
        return false;
    }

    if (pix_fmt != AV_PIX_FMT_YUV420P) {
        // Create filter graph.
        graph_ = avfilter_graph_alloc();
        if (graph_ == nullptr) {
            LOG(ERROR) << "avfilter_graph_alloc failed!";
            return false;
        }
        av_opt_set_int(graph_, "threads", 1, 0);
        // Create "buffer" filter.
        const AVFilter* buffersrc  = avfilter_get_by_name("buffer");
        const std::string buffersrc_args = Sprintf(
            "video_size=%dx%d:pix_fmt=%s:time_base=1/90000", width, height,
            av_get_pix_fmt_name(pix_fmt));
        rc = avfilter_graph_create_filter(&in_, buffersrc, "in", buffersrc_args.c_str(), nullptr,
                                          graph_);
        if (rc < 0) {
            LOG(ERROR) << "avfilter_graph_create_filter(buffer=" << buffersrc_args
                << ") failed: " << FfmpegErrStr(rc);
            return false;
        }
        // Create "buffersink" filter.
        const AVFilter* buffersink = avfilter_get_by_name("buffersink");
        rc = avfilter_graph_create_filter(&out_, buffersink, "out", nullptr, nullptr, graph_);
        if (rc < 0) {
            LOG(ERROR) << "avfilter_graph_create_filter(buffersink) failed: " << FfmpegErrStr(rc);
            return false;
        }
        enum AVPixelFormat pix_fmts[] = { AV_PIX_FMT_YUV420P, AV_PIX_FMT_NONE };
        rc = av_opt_set_int_list(out_, "pix_fmts", pix_fmts, AV_PIX_FMT_NONE,
                                 AV_OPT_SEARCH_CHILDREN);
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
        ADD_FILTER("format", "%s", av_get_pix_fmt_name(AV_PIX_FMT_YUV420P));
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
            LOG(ERROR) << "avfilter_graph_parse_ptr(" << filter_str << ") failed: "
                << FfmpegErrStr(rc);
            return false;
        }
        rc = avfilter_graph_config(graph_, nullptr);
        if (rc < 0) {
            LOG(ERROR) << "avfilter_graph_config failed: " << FfmpegErrStr(rc);
            return false;
        }
    }

    // Create IO.
    rc = avio_open(&fmt_ctx_->pb, output_file.c_str(), AVIO_FLAG_WRITE);
    if (rc < 0) {
        LOG(ERROR) << "avio_open(" << output_file << ") failed: " << FfmpegErrStr(rc);
        return false;
    }

    // Write head.
    fmt_ctx_->flags |= AVFMT_FLAG_NOBUFFER;
    fmt_ctx_->max_delay = 500;
    rc = avformat_write_header(fmt_ctx_, nullptr);
    if (rc < 0) {
        LOG(ERROR) << "avformat_write_header failed: " << FfmpegErrStr(rc);
        return false;
    }
    return true;
}

bool VideoEncoder::EncodeAVFrame(AVFrame* frame) {
    bool success = true;
    // Flush encoder buffer.
    if (frame == nullptr) {
        if ((enc_ctx_->codec->capabilities | AV_CODEC_CAP_DELAY) != 0) success = DoEncode(nullptr);
    } else if (graph_ != nullptr) {
        // Convert.
        int rc = av_buffersrc_add_frame_flags(
            in_, frame, AV_BUFFERSRC_FLAG_KEEP_REF | AV_BUFFERSRC_FLAG_PUSH);
        if (rc < 0) {
            LOG(ERROR) << "av_buffersrc_add_frame_flags failed: " << FfmpegErrStr(rc);
            return false;
        }
        AVFrame* converted = av_frame_alloc();
        rc = av_buffersink_get_frame_flags(out_, converted, AV_BUFFERSINK_FLAG_NO_REQUEST);
        if (rc < 0) {
            LOG(ERROR) << "av_buffersink_get_frame_flags failed: " << FfmpegErrStr(rc);
            return false;
        }
        converted->pts = frame->pts;
        success = DoEncode(converted);
        av_frame_free(&converted);
    } else {
        success = DoEncode(frame);
    }
    return success;
}

bool VideoEncoder::DoEncode(AVFrame* frame) {
    int rc = avcodec_send_frame(enc_ctx_, frame);
    if (rc < 0) {
        LOG(ERROR) << "avcodec_send_frame failed: " << FfmpegErrStr(rc);
        return false;
    }

    while (true) {
        AVPacket* pkt = av_packet_alloc();
        int rc = avcodec_receive_packet(enc_ctx_, pkt);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) {
            av_packet_free(&pkt);
            break;
        }
        if (rc < 0) {
            LOG(ERROR) << "avcodec_receive_packet failed: " << FfmpegErrStr(rc);
            break;
        }
        // ffmpeg might change the pts randomly when it's huge. No idea why though.
        if (frame != nullptr) pkt->dts = pkt->pts = frame->pts;
        rc = av_write_frame(fmt_ctx_, pkt);
        av_packet_free(&pkt);
        if (rc < 0) {
            LOG(ERROR) << "av_write_frame failed: " << FfmpegErrStr(rc);
            return false;
        }
    }
    return true;
}

void VideoEncoder::Close() {
    avfilter_graph_free(&graph_);
    avcodec_free_context(&enc_ctx_);
    if (fmt_ctx_ != nullptr) {
        if (fmt_ctx_->pb != NULL) {
            const int rc = av_write_trailer(fmt_ctx_);
            if (rc < 0) {
                LOG(ERROR) << "av_write_trailer failed: " << FfmpegErrStr(rc);
            }
            avio_closep(&fmt_ctx_->pb);
        }
        avformat_close_input(&fmt_ctx_);
    }
}
