#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "sherpa-onnx/c-api/c-api.h"
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000.0+t.tv_nsec/1000000.0; }
static double start,first;
static int32_t audio_cb(const float *samples,int32_t n,float progress,void *arg) { if(n>0&&first<0)first=now_ms()-start;return 1; }
static char *path(const char *base,const char *name) {char *p=malloc(strlen(base)+strlen(name)+2);sprintf(p,"%s/%s",base,name);return p;}
int main(int argc,char **argv) {
 if(argc!=6) {fprintf(stderr,"family model_dir vocoder text_file output_prefix\n");return 2;}
 const char *family=argv[1],*dir=argv[2];
 if(strcmp(family,"melo") && strcmp(family,"aishell") && strcmp(family,"kokoro") && strcmp(family,"matcha") && strcmp(family,"matcha-zh-en") && strcmp(family,"supertonic")) {fprintf(stderr,"unknown family\n");return 2;}
 SherpaOnnxOfflineTtsConfig c;memset(&c,0,sizeof(c));
 c.model.num_threads=getenv("TTS_THREADS")?atoi(getenv("TTS_THREADS")):2;c.model.provider=getenv("TTS_PROVIDER")?getenv("TTS_PROVIDER"):"cpu";c.max_num_sentences=1;c.silence_scale=0.2f;
  if(!strcmp(family,"melo") || !strcmp(family,"aishell")) {
 c.model.vits.model=path(dir,"model.onnx");c.model.vits.lexicon=path(dir,"lexicon.txt");c.model.vits.tokens=path(dir,"tokens.txt");c.model.vits.noise_scale=0.667f;c.model.vits.noise_scale_w=0.8f;c.model.vits.length_scale=1.0f;
 c.rule_fsts=path(dir,"date.fst");
  } else if(!strcmp(family,"kokoro")) {
  c.model.kokoro.model=path(dir,"model.int8.onnx");c.model.kokoro.voices=path(dir,"voices.bin");c.model.kokoro.tokens=path(dir,"tokens.txt");c.model.kokoro.lexicon=path(dir,"lexicon-zh.txt");c.model.kokoro.lang="zh";c.model.kokoro.length_scale=1;
  c.model.kokoro.data_dir=path(dir,"espeak-ng-data");c.rule_fsts=path(dir,"date-zh.fst");
  } else if(!strcmp(family,"supertonic")) {
 c.model.supertonic.duration_predictor=path(dir,"duration_predictor.int8.onnx");c.model.supertonic.text_encoder=path(dir,"text_encoder.int8.onnx");c.model.supertonic.vector_estimator=path(dir,"vector_estimator.int8.onnx");c.model.supertonic.vocoder=path(dir,"vocoder.int8.onnx");c.model.supertonic.tts_json=path(dir,"tts.json");c.model.supertonic.unicode_indexer=path(dir,"unicode_indexer.bin");c.model.supertonic.voice_style=path(dir,"voice.bin");
  } else {
 c.model.matcha.acoustic_model=path(dir,"model-steps-3.onnx");c.model.matcha.vocoder=argv[3];c.model.matcha.tokens=path(dir,"tokens.txt");c.model.matcha.lexicon=path(dir,"lexicon.txt");c.model.matcha.noise_scale=1;c.model.matcha.length_scale=1;
  if(!strcmp(family,"matcha-zh-en")) c.model.matcha.data_dir=getenv("TTS_ESPEAK_DATA");
  else c.rule_fsts=path(dir,"date.fst");
 }
 double load=now_ms();const SherpaOnnxOfflineTts *tts=SherpaOnnxCreateOfflineTts(&c);load=now_ms()-load;
 if(!tts){fprintf(stderr,"create failed\n");return 3;}
  SherpaOnnxGenerationConfig gen;memset(&gen,0,sizeof(gen));gen.speed=1.0f;gen.sid=getenv("TTS_SPEAKER")?atoi(getenv("TTS_SPEAKER")):0;gen.silence_scale=0.2f;
 if(!strcmp(family,"supertonic")){gen.num_steps=5;gen.extra="{\"lang\":\"en\"}";}
 start=now_ms();first=-1;
 const SherpaOnnxGeneratedAudio *warm=SherpaOnnxOfflineTtsGenerateWithConfig(tts,!strcmp(family,"supertonic")?"Hi.":"你好。",&gen,NULL,NULL);
 if(!warm||warm->n<1)return 4;double warmms=now_ms()-start;SherpaOnnxDestroyOfflineTtsGeneratedAudio(warm);
  printf("{\"family\":\"%s\",\"threads\":%d,\"requestedProvider\":\"%s\",\"speaker\":%d,\"silenceScale\":0.2,\"sampleRate\":%d,\"loadMs\":%.1f,\"warmMs\":%.1f}\n",family,c.model.num_threads,c.model.provider,(int)gen.sid,SherpaOnnxOfflineTtsSampleRate(tts),load,warmms);fflush(stdout);
 FILE *f=fopen(argv[4],"rb");if(!f)return 5;char line[4096];int index=0;
 while(fgets(line,sizeof(line),f)) {
 line[strcspn(line,"\r\n")]=0;if(!*line)continue;start=now_ms();first=-1;
 const SherpaOnnxGeneratedAudio *a=SherpaOnnxOfflineTtsGenerateWithConfig(tts,line,&gen,audio_cb,NULL);
 double elapsed=now_ms()-start;if(!a||a->n<1)return 6;
 double duration=1000.0*a->n/a->sample_rate;
 printf("{\"family\":\"%s\",\"index\":%d,\"synthesisMs\":%.1f,\"firstChunkMs\":%.1f,\"audioMs\":%.1f,\"rtf\":%.4f}\n",family,index,elapsed,first,duration,elapsed/duration);fflush(stdout);
 char dest[512];snprintf(dest,sizeof(dest),"%s-%d.wav",argv[5],index++);SherpaOnnxWriteWave(a->samples,a->n,a->sample_rate,dest);SherpaOnnxDestroyOfflineTtsGeneratedAudio(a);
 }
 fclose(f);SherpaOnnxDestroyOfflineTts(tts);return 0;
}
