#pragma once
#include <stdint.h>
#include <AudioToolbox/AudioToolbox.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef void *SketchSynthRef;
typedef struct {
    int32_t waveform;
    float attack, decay, sustain, release, cutoff, gain;
} SketchSynthParameters;
typedef struct {
    float tune, decay, sweep, sweepTime, click, drive, gain;
} SketchKickParameters;
typedef struct {
    float bow, tone, body, vibrato, attack, release, gain;
} SketchViolinParameters;
typedef struct {
    float texture, brightness, rate, decay, gain;
} SketchShakerParameters;
SketchSynthRef SketchSynthCreate(double sampleRate);
void SketchSynthDestroy(SketchSynthRef synth);
void SketchSynthConfigure(SketchSynthRef synth, SketchSynthParameters parameters);
void SketchSynthConfigureKick(SketchSynthRef synth, SketchKickParameters parameters);
void SketchSynthConfigureOud(SketchSynthRef synth, float pluck, float warmth, float decay, float gain);
void SketchSynthConfigureViolin(SketchSynthRef synth, SketchViolinParameters parameters);
void SketchSynthConfigureShaker(SketchSynthRef synth, SketchShakerParameters parameters);
void SketchSynthNote(SketchSynthRef synth, int32_t pitch, int32_t velocity, int32_t on);
void SketchSynthPanic(SketchSynthRef synth);
void SketchSynthRender(SketchSynthRef synth, float *left, float *right, uint32_t frames);
typedef void *SketchSequenceRef;
SketchSequenceRef SketchSequenceCreate(AudioUnit unit, double bpm);
void SketchSequenceDestroy(SketchSequenceRef sequence);
// Prepare while stopped. The render callback never allocates or locks.
void SketchSequenceAddNote(SketchSequenceRef sequence, double start, double end, uint8_t pitch, uint8_t velocity);
void SketchSequenceAddRegion(SketchSequenceRef sequence, double start, double end);
void SketchSequencePrepare(SketchSequenceRef sequence);
void SketchSequenceStart(SketchSequenceRef sequence, uint64_t hostAnchor, double fromSeconds, double rate);
void SketchSequenceStop(SketchSequenceRef sequence);
#ifdef __cplusplus
}
#endif
