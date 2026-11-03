#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "sherpa-onnx/c-api/c-api.h"
static double now_ms(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000.0+t.tv_nsec/1000000.0;}
static char *path(const char *a,const char *b){char *p=malloc(strlen(a)+strlen(b)+2);sprintf(p,"%s/%s",a,b);return p;}
int main(int argc,char **argv){
 if(argc<4 || (strcmp(argv[1],"base")&&strcmp(argv[1],"qwen"))){fprintf(stderr,"base|qwen model_dir wav...\n");return 2;}
 SherpaOnnxOfflineRecognizerConfig c;memset(&c,0,sizeof(c));c.feat_config.sample_rate=16000;c.feat_config.feature_dim=80;c.decoding_method="greedy_search";c.model_config.num_threads=2;c.model_config.provider="cpu";
 if(!strcmp(argv[1],"base")){
  c.model_config.tokens=path(argv[2],"base-tokens.txt");c.model_config.whisper.encoder=path(argv[2],"base-encoder.int8.onnx");c.model_config.whisper.decoder=path(argv[2],"base-decoder.int8.onnx");c.model_config.whisper.language="";c.model_config.whisper.task="transcribe";c.model_config.whisper.tail_paddings=-1;
 }else{
  c.model_config.qwen3_asr.conv_frontend=path(argv[2],"conv_frontend.onnx");c.model_config.qwen3_asr.encoder=path(argv[2],"encoder.int8.onnx");c.model_config.qwen3_asr.decoder=path(argv[2],"decoder.int8.onnx");c.model_config.qwen3_asr.tokenizer=path(argv[2],"tokenizer");c.model_config.qwen3_asr.max_total_len=512;c.model_config.qwen3_asr.max_new_tokens=128;c.model_config.qwen3_asr.temperature=1e-6f;c.model_config.qwen3_asr.top_p=.8f;c.model_config.qwen3_asr.seed=42;
 }
 double start=now_ms();const SherpaOnnxOfflineRecognizer *r=SherpaOnnxCreateOfflineRecognizer(&c);if(!r)return 3;
 printf("MODEL\t%s\tthreads=2\trequestedProvider=cpu\tloadMs=%.1f\n",argv[1],now_ms()-start);fflush(stdout);
 for(int i=3;i<argc;i++){
  const SherpaOnnxWave *w=SherpaOnnxReadWave(argv[i]);if(!w)return 4;
  const SherpaOnnxOfflineStream *s=SherpaOnnxCreateOfflineStream(r);if(!s)return 5;
  start=now_ms();SherpaOnnxAcceptWaveformOffline(s,w->sample_rate,w->samples,w->num_samples);SherpaOnnxDecodeOfflineStream(r,s);double elapsed=now_ms()-start;
  const SherpaOnnxOfflineRecognizerResult *result=SherpaOnnxGetOfflineStreamResult(s);if(!result)return 6;
  printf("RESULT\t%s\taudioMs=%.1f\tdecodeMs=%.1f\t%s\n",argv[i],1000.0*w->num_samples/w->sample_rate,elapsed,result->text);fflush(stdout);
  SherpaOnnxDestroyOfflineRecognizerResult(result);SherpaOnnxDestroyOfflineStream(s);SherpaOnnxFreeWave(w);
 }
 SherpaOnnxDestroyOfflineRecognizer(r);return 0;
}
