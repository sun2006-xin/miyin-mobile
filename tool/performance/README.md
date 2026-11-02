# Android TTS 合成基准

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
```

可用环境变量：`TTS_THREADS`（默认2）、`TTS_PROVIDER`（默认cpu）。检查stderr是否回退CPU，不能把请求了加速后端当作实际加速。

每行输入一个测试样本；先执行一次固定“你好”预热，再记录每条的合成、首PCM回调、音频时长和RTF，生成WAV用于后续质量检查。WAV不是用户录音。注意：首回调时间不是点击到可听首响；性能基准不证明发音正确。若比较不同模型，应记录音色、采样率、实际音频时长与许可，不能只报告速度比例。采用ABBA顺序并保存所有输出，包括失败与回退。

当前只启用date.fst；固定基准样本没有数字。数字、混合语言、生产播放器、热状态与并行LLM竞争需要另外覆盖。参考 `docs/product/AI实时语音接入与本地合成对比-2026-11-02.md`。
