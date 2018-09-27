#ifndef UTILS_HPP_
#define UTILS_HPP_

#include <string>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavdevice/avdevice.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libavutil/time.h>
}  // extern "C"

#ifndef ARRAYSIZE
#define ARRAYSIZE(buf) sizeof(buf)/sizeof(buf[0])
#endif

inline std::string Sprintf(const char* format, ...) {
    char buf[1000];
    va_list ap;
    va_start(ap, format);
    vsnprintf(buf, ARRAYSIZE(buf), format, ap);
    va_end(ap);
    return buf;
}

inline std::string FfmpegErrStr(int rc) {
    char err_buf[200];
    if (av_strerror(rc, err_buf, ARRAYSIZE(err_buf)) == 0) {
        return Sprintf("%s(%d)", err_buf, rc);
    }
    return Sprintf("(%d)", rc);
}

inline void InitFfmpeg(int log_level) {
    setenv("AV_LOG_FORCE_COLOR", "1", 0);
#if !FF_API_NEXT
    avcodec_register_all();
    av_register_all();
    avfilter_register_all();
#endif
    avdevice_register_all();
    avformat_network_init();
    av_log_set_level(log_level);
}

#endif // UTILS_HPP_
