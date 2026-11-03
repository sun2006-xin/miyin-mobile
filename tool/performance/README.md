# Android TTS 合成基准

## ASR整段对照

`android_asr_benchmark.c` 支持 `base|qwen model_dir wav...`，用相同NDK和APK原生库编译。base目录为`base-encoder.int8.onnx/base-decoder.int8.onnx/base-tokens.txt`；Qwen目录为`conv_frontend.onnx/encoder.int8.onnx/decoder.int8.onnx/tokenizer/`。CPU2线程、greedy、自动语种；Whisper默认尾部补齐，Qwen max_total_len512/max_new_tokens128、seed42，适合当前短样本，长音频需要另设分段和输出上限。

输出MODEL初始化时间和每段RESULT音频时长、整段解码耗时、识别文字。结果TSV中保留原始输出，错误UTF8也需保留原始字节。一次加载后顺序处理，不额外推理预热，第一条可能包含首次推理开销；不是原生流式首字延迟，也不是应用端VAD/收尾性能。应按相同顺序输入同一批音频，覆盖单独进程复测，不能把六段样本当总体准确率。

本轮只使用开发者合成样本与官方公开样本，不读取用户录音。实际结果及限制见`docs/product/开源前能力盘点与语音识别对照-2026-11-02.md`。

## TTS合成基准

`android_tts_benchmark.c` 是独立的 sherpa-onnx C API 合成基准，不接入生产应用、不读取会话或麦克风。只接收开发者准备的合成测试文本。

使用与 APK 相同版本的 `sherpa-onnx/c-api/c-api.h` 和从该 APK 提取的 arm64 `libsherpa-onnx-c-api.so`、`libonnxruntime.so` 编译；将它们保存在独立测试目录。需要对应模型、lexicon、tokens、date.fst，Matcha 还需要 vocoder。不要将受限制的实验模型直接加入 APK。

示例编译（NDK clang，替换路径）：

```text
clang --target=aarch64-linux-android24 -O2 -I<同版本sherpa源码> android_tts_benchmark.c -L<APK原生库目录> -lsherpa-onnx-c-api -lonnxruntime -Wl,-rpath,$ORIGIN/lib -o tts-bench
```

设备端运行参数：

```text
LD_LIBRARY_PATH=./lib ./tts-bench melo ./melo-model unused ./synthetic-text.txt ./melo-result
LD_LIBRARY_PATH=./lib ./tts-bench matcha ./matcha-model ./vocos.onnx ./synthetic-text.txt ./matcha-result
LD_LIBRARY_PATH=./lib ./tts-bench aishell ./aishell-model unused ./synthetic-text.txt ./aishell-result
LD_LIBRARY_PATH=./lib ./tts-bench kokoro ./kokoro-model unused ./synthetic-text.txt ./kokoro-result
LD_LIBRARY_PATH=./lib TTS_ESPEAK_DATA=./espeak-ng-data ./tts-bench matcha-zh-en ./matcha-zh-en-model ./vocos-16khz-univ.onnx ./synthetic-text.txt ./matcha-zh-en-result
```

可用环境变量：`TTS_THREADS`（默认2）、`TTS_PROVIDER`（默认cpu）、`TTS_SPEAKER`（默认0）。检查stderr是否回退CPU，不能把请求了加速后端当作实际加速。

`aishell` 使用 VITS 配置；`kokoro` 需要 `model.int8.onnx/voices.bin/tokens.txt/lexicon-zh.txt/date-zh.fst/espeak-ng-data`，语言提示固定为中文。`matcha-zh-en` 需要 `model-steps-3.onnx/tokens.txt/lexicon.txt`、独立16kHz声码器和 `TTS_ESPEAK_DATA`；该模式不启用日期规则，仅用于普通文本对照。中文成功不证明英文音素回退可用，也不证明原生库或数据的发布许可已审查。不要为通过初始化而创建空的占位数据文件。

每行输入一个测试样本；先执行一次固定“你好”预热，再记录每条的合成、首PCM回调、音频时长和RTF，生成WAV用于后续质量检查。WAV不是用户录音。注意：首回调时间不是点击到可听首响；性能基准不证明发音正确。若比较不同模型，应记录音色、采样率、实际音频时长与许可，不能只报告速度比例。采用ABBA顺序并保存所有输出，包括失败与回退。

规则按family配置：Melo/AISHELL/中文Matcha用date.fst，Kokoro用date-zh.fst，中英Matcha不启规则；固定基准样本没有数字。数字、混合语言、生产播放器、热状态与并行LLM竞争需要另外覆盖。输出记录请求后端，仍须检查stderr确认是否回退。参考 `docs/product/AI实时语音接入与本地合成对比-2026-11-02.md` 和 `docs/product/本地中文TTS候选真机对照-2026-11-02.md`。
