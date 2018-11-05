//
//  AudioMixing.m
//  ffmpeg
//
//  Created by Apple on 2018/10/31.
//  Copyright © 2018年 XC. All rights reserved.
//

#import "AudioMixing.h"

#include "avcodec.h"
#include "avformat.h"
#include "buffersink.h"
#include "buffersrc.h"
#include "opt.h"
#include "audio_fifo.h"
#include "fifo.h"
#include "channel_layout.h"
#include <stdio.h>
//#include <uin>

static char* filter_desc = "[in0][in1]amix=inputs=2[out]";
static AVFormatContext *fmt_gctx;
static AVCodecContext *dec_gctx;
static AVFormatContext *fmt_lctx;
static AVCodecContext *dec_lctx;
static AVFormatContext *fmt_out_ctx;

AVFilterContext *buffersink_ctx;
AVFilterContext *buffersrc_gctx;
AVFilterContext *buffersrc_lctx;
AVFilterGraph *filter_graph;
int audio_stream_gindex = -1;
int audio_stream_lindex = -1;
int _index_a_out = 0;

AVAudioFifo *fifo_g = NULL;
AVAudioFifo *fifo_l = NULL;


@implementation AudioMixing

void InitRecorder(){
    av_register_all();
//    avcodec_register_all();
//    avfilter_register_all();
}

int open_g_input_file(const char *filename){
    int ret;
    AVCodec *dec;
    if ((ret = avformat_open_input(&fmt_gctx, filename, NULL, NULL)) < 0) {
        NSLog(@"打开文件失败");
        return ret;
    }
    if ((ret = avformat_find_stream_info(fmt_gctx, NULL) < 0)) {
        NSLog(@"查找stream信息失败");
        return ret;
    }
    ret = av_find_best_stream(fmt_gctx, AVMEDIA_TYPE_AUDIO, -1, -1, &dec, 0);
    if (ret < 0) {
        NSLog(@"查找音频frame失败");
        return ret;
    }
//    audio_stream_index = ret;
//    if (index == 0) {
        audio_stream_gindex = ret;
//    }else{
//        audio_stream_lindex = ret;
//    }
    
    dec_gctx = avcodec_alloc_context3(dec);
    if (!dec_gctx) {
        return AVERROR(ENOMEM);
    }
    avcodec_parameters_to_context(dec_gctx, fmt_gctx->streams[audio_stream_gindex]->codecpar);
    if ((ret = avcodec_open2(dec_gctx, dec, NULL)) < 0) {
        NSLog(@"打开编码器失败");
        return ret;
    }
    
    return 0;
}

int open_l_input_file(const char *filename){
    int ret;
    AVCodec *dec;
    if ((ret = avformat_open_input(&fmt_lctx, filename, NULL, NULL)) < 0) {
        NSLog(@"打开文件失败");
        return ret;
    }
    if ((ret = avformat_find_stream_info(fmt_lctx, NULL) < 0)) {
        NSLog(@"查找stream信息失败");
        return ret;
    }
    ret = av_find_best_stream(fmt_lctx, AVMEDIA_TYPE_AUDIO, -1, -1, &dec, 0);
    if (ret < 0) {
        NSLog(@"查找音频frame失败");
        return ret;
    }
    audio_stream_lindex = ret;
    
    dec_lctx = avcodec_alloc_context3(dec);
    if (!dec_lctx) {
        return AVERROR(ENOMEM);
    }
    avcodec_parameters_to_context(dec_lctx, fmt_lctx->streams[audio_stream_lindex]->codecpar);
    if ((ret = avcodec_open2(dec_lctx, dec, NULL)) < 0) {
        NSLog(@"打开编码器失败");
        return ret;
    }
    
    return 0;
}

static int open_output_file(const char *output_file){
    int ret = 0;
    ret = avformat_alloc_output_context2(&fmt_out_ctx, NULL, NULL, output_file);
    if (ret < 0) {
        NSLog(@"初始化失败");
        return ret;
    }
    AVStream *stream = NULL;
    stream = avformat_new_stream(fmt_out_ctx, NULL);
    if (stream == NULL) {
        NSLog(@"初始化Stream失败");
        return -1;
    }
    stream->codecpar->codec_type = AVMEDIA_TYPE_AUDIO;
    AVCodec *codec_mp3 = avcodec_find_encoder(AV_CODEC_ID_MP3);
    stream->codec->codec = codec_mp3;
    stream->codecpar->sample_rate = 44100;
    stream->codecpar->channels = 2;
    stream->codecpar->channel_layout = av_get_channel_layout("2");
    stream->codec->sample_fmt = AV_SAMPLE_FMT_S16P;
    stream->codecpar->bit_rate = 32000;
    stream->time_base = (AVRational){1,stream->codecpar->sample_rate};
    stream->codecpar->codec_tag = 0;
    stream->start_time = 0;
    if (fmt_out_ctx->oformat->flags & AVFMT_GLOBALHEADER)
        stream->codec->flags |= CODEC_FLAG_GLOBAL_HEADER;
    
    AVCodecContext *codec_ctx = avcodec_alloc_context3(codec_mp3);
    codec_ctx->time_base = (AVRational){1,stream->codecpar->sample_rate};
    codec_ctx->sample_fmt = AV_SAMPLE_FMT_S16P;
    if (avcodec_open2(codec_ctx, stream->codec->codec, NULL) < 0){
        printf("Mixer: failed to call avcodec_open2\n");
        return -1;
    }
    if (!(fmt_out_ctx->oformat->flags & AVFMT_NOFILE)){
        if (avio_open(&fmt_out_ctx->pb, output_file, AVIO_FLAG_WRITE) < 0){
            printf("Mixer: failed to call avio_open\n");
            return -1;
        }
    }
    if (avformat_write_header(fmt_out_ctx, NULL) < 0) {
        NSLog(@"写入文件头失败");
        return -1;
    }
    fifo_g = av_audio_fifo_alloc(fmt_gctx->streams[audio_stream_gindex]->codec->sample_fmt, fmt_gctx->streams[audio_stream_gindex]->codecpar->channels, fmt_gctx->streams[audio_stream_gindex]->codecpar->frame_size * 30);
    fifo_l = av_audio_fifo_alloc(fmt_lctx->streams[audio_stream_gindex]->codec->sample_fmt, fmt_lctx->streams[audio_stream_gindex]->codecpar->channels, fmt_lctx->streams[audio_stream_gindex]->codecpar->frame_size * 30);
    
    return 0;
}

static int init_filters(const char *filters_descr){
    char arg_g[512];
    char *pad_name_g = "in0";
    char arg_l[512];
    char *pad_name_l = "in1";
    
    AVFilter *filter_src_g = avfilter_get_by_name("abuffer");
    AVFilter *filter_src_l = avfilter_get_by_name("abuffer");
    AVFilter *filter_sink = avfilter_get_by_name("abuffersink");
    
    AVFilterInOut *filter_input_g = avfilter_inout_alloc();
    AVFilterInOut *filter_input_l = avfilter_inout_alloc();
    AVFilterInOut *filter_input = avfilter_inout_alloc();
    filter_graph = avfilter_graph_alloc();
    
    sprintf(arg_g, sizeof(arg_g),
             "time_base=%d/%d:sample_rate=%d:sample_fmt=%s:channel_layout=0x%I64x",
             dec_gctx->time_base.num, dec_gctx->time_base.den, dec_gctx->sample_rate,
             av_get_sample_fmt_name(dec_gctx->sample_fmt), dec_gctx->channel_layout);
    sprintf(arg_l, sizeof(arg_l),
             "time_base=%d/%d:sample_rate=%d:sample_fmt=%s:channel_layout=0x%I64x",
             dec_lctx->time_base.num, dec_lctx->time_base.den, dec_lctx->sample_rate,
             av_get_sample_fmt_name(dec_lctx->sample_fmt), dec_lctx->channel_layout);
    
    int ret = 0;
    ret = avfilter_graph_create_filter(&buffersrc_gctx, filter_src_g, pad_name_g, NULL, NULL, filter_graph);
    if (ret < 0) {
        NSLog(@"创建srcg失败");
        return ret;
    }
    ret = avfilter_graph_create_filter(&buffersrc_lctx, filter_src_l, pad_name_l, NULL, NULL, filter_graph);
    if (ret < 0) {
        NSLog(@"创建srcl失败");
        return ret;
    }
    ret = avfilter_graph_create_filter(&buffersink_ctx, filter_sink, "out", NULL, NULL, filter_graph);
    if (ret < 0) {
        NSLog(@"创建sink失败");
        return ret;
    }
    filter_input_g->name = av_strdup(pad_name_g);
    filter_input_g->filter_ctx = buffersrc_gctx;
    filter_input_g->pad_idx = 0;
    filter_input_g->next = filter_input_l;
    
    filter_input_l->name = av_strdup(pad_name_l);
    filter_input_l->filter_ctx = buffersrc_lctx;
    filter_input_l->pad_idx = 0;
    filter_input_l->next = NULL;
    
    filter_input->name = av_strdup("out");
    filter_input->filter_ctx = buffersink_ctx;
    filter_input->pad_idx = 0;
    filter_input->next = NULL;
    
    AVFilterInOut *filter_output[2];
    filter_output[0] = filter_input_g;
    filter_output[1] = filter_input_l;
    
    ret = avfilter_graph_parse_ptr(filter_graph, filter_desc, &filter_input, filter_output, NULL);
    if (ret < 0) {
        NSLog(@"配置命令行参数失败");
        return ret;
    }
    ret = avfilter_graph_config(filter_graph, NULL);
    if (ret < 0) {
        NSLog(@"配置参数失败");
        return ret;
    }
    avfilter_inout_free(&filter_input);
    avfilter_inout_free(filter_output);
    av_free(filter_sink);
    av_free(filter_src_g);
    av_free(filter_src_l);
    
    return 0;
}

+ (void)ffmpegAudioMixing:(NSString*)inFilePathOne inFilePathTwo:(NSString *)inFilePathTwo outFilePath:(NSString*)outFilePath{

    InitRecorder();
//    open_input_file([inFilePathOne UTF8String], fmt_gctx, audio_stream_gindex, dec_gctx,0);
    open_g_input_file([inFilePathOne UTF8String]);
//    open_input_file([inFilePathTwo UTF8String], fmt_lctx, audio_stream_lindex, dec_lctx,1);
    open_l_input_file([inFilePathTwo UTF8String]);
    open_output_file([outFilePath UTF8String]);
    init_filters(filter_desc);
    int64_t g_count = fmt_gctx->streams[audio_stream_gindex]->nb_frames;
    NSLog(@"%d ---- %ld",audio_stream_gindex,audio_stream_lindex);
    int64_t l_count = fmt_lctx->streams[audio_stream_lindex]->nb_frames;
    int current_idnex = 0;
    AVFrame *g_frame = av_frame_alloc();
    AVFrame *l_frame = av_frame_alloc();
    AVPacket *g_packet = (AVPacket *)malloc(sizeof(AVPacket));
    AVPacket *l_packet = (AVPacket *)malloc(sizeof(AVPacket));
    while (current_idnex < MAX(g_count, l_count)) {
        av_read_frame(fmt_gctx, g_packet);
        if (g_packet->stream_index == audio_stream_gindex) {
            avcodec_send_packet(dec_gctx, g_packet);
            int ret = avcodec_receive_frame(dec_gctx, g_frame);
            ret = av_buffersrc_add_frame(buffersrc_gctx, g_frame);
        }
        av_read_frame(fmt_lctx, l_packet);
        if (l_packet->stream_index == audio_stream_lindex) {
            avcodec_send_packet(dec_lctx, l_packet);
            int ret = avcodec_receive_frame(dec_lctx, l_frame);
            if (ret < 0) {
                NSLog(@"失败");
            }
            ret = av_buffersrc_add_frame(buffersrc_lctx, l_frame);
        }
        AVFrame *out_frame = av_frame_alloc();
        int ret = av_buffersink_get_frame(buffersink_ctx, out_frame);
        if (ret < 0) {
            NSLog(@"失败");
        }
//        av_wri
        AVPacket *out_packet = NULL;
        if (out_frame->data[0] != NULL) {
            av_init_packet(out_packet);
            out_packet->stream_index = _index_a_out;
            out_packet->pts = fmt_out_ctx->streams[_index_a_out]->codec->frame_size;
            out_packet->dts = out_packet->pts;
            out_packet->duration = fmt_out_ctx->streams[_index_a_out]->codec->frame_size;
            av_interleaved_write_frame(fmt_out_ctx, out_packet);
        }
        
    }
    av_write_trailer(fmt_out_ctx);
}

@end
