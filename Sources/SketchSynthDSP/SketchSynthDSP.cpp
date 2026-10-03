#include "SketchSynthDSP.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <new>

namespace {
constexpr double pi = 3.14159265358979323846;
struct Event { int pitch, velocity, on; };
struct Voice {
    int pitch = -1, stage = 0;
    double phase = 0, step = 0, level = 0, velocity = 0, releaseStep = 0, low1 = 0, low2 = 0;
    uint64_t age = 0;
    double elapsed = 0, noiseLast = 0;
    uint32_t noise = 1234567;
    double harmonics[24]{}, harmonicTargets[24]{};
    double shell1 = 0, shell2 = 0, shellCoefficient = 0;
};
struct Synth {
    double rate;
    std::atomic<int> waveform{1};
    std::atomic<int> instrument{0}; // synth, kick, oud, violin, shaker
    std::atomic<float> bow{0.55f}, tone{0.5f}, body{0.6f}, vibrato{0.35f};
    std::atomic<float> texture{0.5f}, brightness{0.6f}, shakeRate{5}, shakeDecay{0.16f};
    std::atomic<float> oudPluck{0.5f}, oudWarmth{0.55f}, oudDecay{1.2f};
    std::atomic<float> tune{50}, kickDecay{0.5f}, sweep{24}, sweepTime{0.035f}, click{0.2f}, drive{0.2f};
    std::atomic<float> attack{0.01f}, decay{0.2f}, sustain{0.65f}, release{0.3f}, cutoff{4000}, gain{0.3f};
    Event events[256]{};
    std::atomic<uint32_t> head{0}, tail{0};
    std::atomic<bool> panic{false};
    Voice voices[32]{};
    uint64_t age = 0;
    explicit Synth(double r) : rate(r) {}
};
static_assert(std::atomic<float>::is_always_lock_free && std::atomic<uint32_t>::is_always_lock_free,
              "The render callback requires lock-free atomics");
float bounded(float x, float low, float high) { return std::isfinite(x) ? std::clamp(x, low, high) : low; }
double blep(double p, double step) {
    if (p < step) { p /= step; return p + p - p * p - 1; }
    if (p > 1 - step) { p = (p - 1) / step; return p * p + p + p + 1; }
    return 0;
}
double wave(double p, double step, int shape) {
    if (shape == 0) return std::sin(2 * pi * p);
    if (shape == 1) return 2 * p - 1 - blep(p, step);
    if (shape == 2) return (p < 0.5 ? 1.0 : -1.0) + blep(p, step) - blep(std::fmod(p + 0.5, 1.0), step);
    // Band-limited triangle via odd harmonics below Nyquist.
    double value = 0;
    for (int n = 1; n <= 19 && n * step < 0.48; n += 2)
        value += ((n % 4 == 1) ? 1.0 : -1.0) * std::sin(2 * pi * p * n) / (n * n);
    return value * 8 / (pi * pi);
}
}
extern "C" SketchSynthRef SketchSynthCreate(double rate) {
    if (!std::isfinite(rate) || rate < 8000 || rate > 192000) return nullptr;
    return new (std::nothrow) Synth(rate);
}
extern "C" void SketchSynthDestroy(SketchSynthRef ref) { delete static_cast<Synth *>(ref); }
extern "C" void SketchSynthConfigure(SketchSynthRef ref, SketchSynthParameters p) {
    auto *s = static_cast<Synth *>(ref);
    s->waveform.store(std::clamp(p.waveform, 0, 3));
    s->attack.store(bounded(p.attack, 0.002f, 3)); s->decay.store(bounded(p.decay, 0.01f, 3));
    s->sustain.store(bounded(p.sustain, 0, 1)); s->release.store(bounded(p.release, 0.01f, 5));
    s->cutoff.store(bounded(p.cutoff, 40, 18000)); s->gain.store(bounded(p.gain, 0, 0.6f));
    s->instrument.store(0);
}
extern "C" void SketchSynthConfigureKick(SketchSynthRef ref, SketchKickParameters p) {
    auto *s = static_cast<Synth *>(ref);
    s->tune.store(bounded(p.tune, 30, 100)); s->kickDecay.store(bounded(p.decay, 0.08f, 2));
    s->sweep.store(bounded(p.sweep, 0, 36)); s->sweepTime.store(bounded(p.sweepTime, 0.005f, 0.15f));
    s->click.store(bounded(p.click, 0, 1)); s->drive.store(bounded(p.drive, 0, 1));
    s->gain.store(bounded(p.gain, 0, 0.6f)); s->instrument.store(1);
}
extern "C" void SketchSynthConfigureOud(SketchSynthRef ref, float pluck, float warmth, float decay, float gain) {
    auto *s = static_cast<Synth *>(ref);
    s->oudPluck.store(bounded(pluck, 0, 1)); s->oudWarmth.store(bounded(warmth, 0, 1));
    s->oudDecay.store(bounded(decay, 0.15f, 3)); s->gain.store(bounded(gain, 0, 0.6f));
    s->instrument.store(2);
}
extern "C" void SketchSynthConfigureViolin(SketchSynthRef ref, SketchViolinParameters p) {
    auto *s = static_cast<Synth *>(ref);
    s->bow.store(bounded(p.bow, 0, 1)); s->tone.store(bounded(p.tone, 0, 1));
    s->body.store(bounded(p.body, 0, 1)); s->vibrato.store(bounded(p.vibrato, 0, 1));
    s->attack.store(bounded(p.attack, 0.015f, 0.8f)); s->release.store(bounded(p.release, 0.03f, 1.5f));
    s->gain.store(bounded(p.gain, 0, 0.6f)); s->instrument.store(3);
}
extern "C" void SketchSynthConfigureShaker(SketchSynthRef ref, SketchShakerParameters p) {
    auto *s = static_cast<Synth *>(ref);
    s->texture.store(bounded(p.texture, 0, 1)); s->brightness.store(bounded(p.brightness, 0, 1));
    s->shakeRate.store(bounded(p.rate, 2, 16)); s->shakeDecay.store(bounded(p.decay, 0.04f, 0.4f));
    s->gain.store(bounded(p.gain, 0, 0.6f)); s->instrument.store(4);
}
extern "C" void SketchSynthNote(SketchSynthRef ref, int32_t pitch, int32_t velocity, int32_t on) {
    auto *s = static_cast<Synth *>(ref);
    if (pitch < 0 || pitch > 127) return;
    const auto head = s->head.load(std::memory_order_relaxed);
    const auto next = (head + 1) % 256;
    if (next == s->tail.load(std::memory_order_acquire)) { s->panic.store(true); return; }
    s->events[head] = {pitch, std::clamp(velocity, 0, 127), on};
    s->head.store(next, std::memory_order_release);
}
extern "C" void SketchSynthPanic(SketchSynthRef ref) {
    auto *s = static_cast<Synth *>(ref);
    const auto head = s->head.load(std::memory_order_relaxed), next = (head + 1) % 256;
    if (next == s->tail.load(std::memory_order_acquire)) { s->panic.store(true); return; }
    s->events[head] = {-1, 0, 0};
    s->head.store(next, std::memory_order_release);
}
extern "C" void SketchSynthRender(SketchSynthRef ref, float *left, float *right, uint32_t frames) {
    auto *s = static_cast<Synth *>(ref);
    // Audio-thread ownership of voices; the UI/MIDI thread only writes the SPSC
    // event queue and atomic parameters. No allocation, locks, or disk access here.
    if (s->panic.exchange(false)) {
        for (auto &v : s->voices) v = Voice{};
        s->tail.store(s->head.load(std::memory_order_acquire), std::memory_order_release);
    }
    const double a = 1 / (s->attack.load() * s->rate), d = 1 / (s->decay.load() * s->rate);
    const double sustain = s->sustain.load(), release = s->release.load(), gain = s->gain.load();
    const double alpha = 1 - std::exp(-2 * pi * std::min(double(s->cutoff.load()), s->rate * 0.45) / s->rate);
    const int shape = s->waveform.load();
    const int instrument = s->instrument.load();
    const bool kick = instrument == 1, oud = instrument == 2, violin = instrument == 3, shaker = instrument == 4;
    const double bow = s->bow.load(), tone = s->tone.load(), bodySize = s->body.load(), vibrato = s->vibrato.load();
    const double texture = s->texture.load(), brightness = s->brightness.load();
    const double shakeRate = s->shakeRate.load(), shakeDecay = s->shakeDecay.load();
    const double shellRadius = std::exp(-1 / (s->rate * (0.0015 + texture * 0.007)));
    const double shakeFilter = 1 - std::exp(-2 * pi * std::min(1200 + brightness * 12000, s->rate * 0.4) / s->rate);
    const double pluck = s->oudPluck.load(), warmth = s->oudWarmth.load(), oudDecay = s->oudDecay.load();
    const double mute = std::exp(-1 / (0.045 * s->rate));
    const double tune = s->tune.load(), kickDecay = s->kickDecay.load(), sweep = s->sweep.load();
    const double sweepTime = s->sweepTime.load(), click = s->click.load(), drive = 1 + s->drive.load() * 8;
    auto tail = s->tail.load(std::memory_order_relaxed);
    const auto head = s->head.load(std::memory_order_acquire);
    while (tail != head) {
        const auto e = s->events[tail]; tail = (tail + 1) % 256;
        if (e.pitch == -1) { for (auto &v : s->voices) v = Voice{}; continue; }
        if (e.on && e.velocity > 0) {
            Voice *chosen = nullptr;
            for (auto &v : s->voices) if (v.pitch == e.pitch && v.stage) { chosen = &v; break; }
            if (!chosen) for (auto &v : s->voices) if (!v.stage) { chosen = &v; break; }
            if (!chosen) chosen = &*std::min_element(std::begin(s->voices), std::end(s->voices),
                [](const Voice &x, const Voice &y) { return x.age < y.age; });
            *chosen = Voice{}; chosen->pitch = e.pitch; chosen->stage = 1;
            chosen->velocity = e.velocity / 127.0; chosen->age = ++s->age;
            chosen->step = std::min(0.48, 440 * std::exp2((e.pitch - 69) / 12.0) / s->rate);
            if (oud || shaker) chosen->level = 1;
            if (violin || shaker) chosen->noise += uint32_t(e.pitch) * 747796405u;
        } else if (!kick) {
            for (auto &v : s->voices) if (v.pitch == e.pitch && v.stage) {
                v.stage = 4; v.releaseStep = v.level / (release * s->rate);
            }
        }
    }
    s->tail.store(tail, std::memory_order_release);
    // Body/formant weights are prepared once per block, then smoothly interpolated.
    for (auto &v : s->voices) {
        if (!v.stage) continue;
        if (violin) {
            double energy = 0;
            for (int n = 1; n <= 24; ++n) {
                const double f = n * v.step * s->rate;
                const double lowBody = 1 / (1 + std::pow((f - 500) / 180, 2));
                const double bridge = 1 / (1 + std::pow((f - 2700) / 900, 2));
                const double weight = n * v.step < 0.45
                    ? std::exp(-f / (1800 + tone * 10000)) / std::pow(n, 1.15 - bow * 0.4)
                        * (0.9 + bodySize * (lowBody * 2 + bridge * 3)) : 0;
                v.harmonicTargets[n - 1] = weight; energy += weight * weight;
            }
            const double scale = 0.6 / std::sqrt(std::max(energy, 1e-12));
            for (int n = 0; n < 24; ++n) v.harmonicTargets[n] *= scale;
        } else if (shaker) {
            const double frequency = std::clamp((1800 + brightness * 4200) * std::exp2((v.pitch - 60) / 36.0), 300.0, s->rate * 0.32);
            v.shellCoefficient = 2 * shellRadius * std::cos(2 * pi * frequency / s->rate);
        }
    }
    for (uint32_t i = 0; i < frames; ++i) {
        double mixed = 0;
        for (auto &v : s->voices) {
            if (!v.stage) continue;
            if (violin) {
                if (v.stage == 4) {
                    v.level = std::max(0.0, v.level - v.releaseStep);
                    if (v.level <= 0) { v.stage = 0; continue; }
                } else { v.level = std::min(1.0, v.level + a); }
                const double step = v.step * std::exp2(vibrato * 0.35 / 12 * std::sin(2 * pi * 5.6 * v.elapsed)
                    * std::min(1.0, v.elapsed / 0.35));
                double previous = 0, partial = std::sin(2 * pi * v.phase), signal = 0;
                const double multiplier = 2 * std::cos(2 * pi * v.phase);
                for (int n = 0; n < 24; ++n) {
                    v.harmonics[n] += 0.002 * (v.harmonicTargets[n] - v.harmonics[n]);
                    signal += partial * v.harmonics[n];
                    const double next = multiplier * partial - previous; previous = partial; partial = next;
                }
                v.noise = v.noise * 1664525u + 1013904223u;
                const double noise = double(v.noise) / 2147483648.0 - 1;
                v.low1 += 0.08 * (noise - v.low1);
                signal += (noise - v.low1) * (0.006 + bow * 0.025) * v.velocity;
                mixed += signal * v.level * v.velocity * gain;
                v.phase += step; if (v.phase >= 1) v.phase -= 1;
                v.elapsed += 1 / s->rate;
                continue;
            }
            if (shaker) {
                if (v.stage == 4 && v.elapsed >= shakeDecay) { v.stage = 0; continue; }
                // Random bead impacts excite a damped shell, with an airy friction layer.
                v.noise = v.noise * 1664525u + 1013904223u;
                const bool collision = double(v.noise) / 4294967296.0 < (250 + texture * 3000) / s->rate;
                v.noise = v.noise * 1664525u + 1013904223u;
                const double noise = double(v.noise) / 2147483648.0 - 1;
                const double shell = (collision ? noise * 0.12 : 0) + v.shellCoefficient * v.shell1 - shellRadius * shellRadius * v.shell2;
                v.shell2 = v.shell1; v.shell1 = shell;
                const double friction = (noise - v.noiseLast) * 0.2;
                v.noiseLast = noise;
                v.low1 += shakeFilter * (shell * 2 + friction - v.low1);
                const double envelope = std::min(1.0, v.elapsed / 0.0015) * std::exp(-5 * v.elapsed / shakeDecay);
                mixed += v.low1 * envelope * v.velocity * gain * 1.8;
                v.elapsed += 1 / s->rate;
                v.phase += shakeRate / s->rate;
                if (v.phase >= 1 && v.stage != 4) { v.phase -= 1; v.elapsed = 0; }
                continue;
            }
            if (oud) {
                const double t = v.elapsed, frequency = v.step * s->rate;
                if (t >= oudDecay || v.level < 0.0001) { v.stage = 0; continue; }
                if (v.stage == 4) v.level *= mute;
                // Decaying plucked harmonics, a lightly detuned paired course, and plectrum noise.
                const double p1 = 2 * pi * v.phase, p2 = 2 * pi * t * frequency * 1.0017;
                const double position = pi * (0.12 + pluck * 0.3);
                double a1 = 0, b1 = std::sin(p1), a2 = 0, b2 = std::sin(p2), ap = 0, bp = std::sin(position);
                const double c1 = 2 * std::cos(p1), c2 = 2 * std::cos(p2), cp = 2 * std::cos(position);
                const double damping = (0.94 - warmth * 0.28) * std::exp(-t * (1 + warmth * 2) / oudDecay);
                double body = 0, amplitude = 1;
                for (int n = 1; n <= 12 && n * v.step * 1.0017 < 0.49; ++n) {
                    body += (b1 + 0.45 * b2) * bp * amplitude / n;
                    const double next1 = c1 * b1 - a1, next2 = c2 * b2 - a2, nextP = cp * bp - ap;
                    a1 = b1; b1 = next1; a2 = b2; b2 = next2; ap = bp; bp = nextP; amplitude *= damping;
                }
                v.noise = v.noise * 1664525u + 1013904223u;
                body += (double(v.noise) / 2147483648.0 - 1) * pluck * 0.08 * std::exp(-t / 0.008);
                const double envelope = std::min(1.0, t / 0.001) * std::exp(-5 * t / oudDecay)
                    * std::min(1.0, (oudDecay - t) / 0.008) * v.level;
                mixed += body * envelope * v.velocity * gain * 0.7;
                v.phase += v.step; if (v.phase >= 1) v.phase -= 1;
                v.elapsed += 1 / s->rate;
                continue;
            }
            if (kick) {
                const double t = v.elapsed;
                if (t >= kickDecay) { v.stage = 0; continue; }
                const double frequency = tune * std::exp2(sweep / 12 * std::exp(-t / sweepTime));
                const double envelope = std::min(1.0, t / 0.0015) * std::exp(-6 * t / kickDecay)
                    * std::min(1.0, (kickDecay - t) / 0.008);
                v.noise = v.noise * 1664525u + 1013904223u;
                const double noise = double(v.noise) / 2147483648.0 - 1;
                const double transient = (noise - v.noiseLast) * 0.5 * click * std::exp(-t / 0.006)
                    * std::min(1.0, t / 0.0005);
                v.noiseLast = noise;
                const double body = std::sin(2 * pi * v.phase) * envelope;
                mixed += std::tanh((body + transient) * drive) / std::tanh(drive) * gain * v.velocity;
                v.phase += frequency / s->rate; if (v.phase >= 1) v.phase -= 1;
                v.elapsed += 1 / s->rate;
                continue;
            }
            if (v.stage == 1) { v.level = std::min(1.0, v.level + a); if (v.level >= 1) v.stage = 2; }
            else if (v.stage == 2) { v.level = std::max(sustain, v.level - d * (1 - sustain)); if (v.level <= sustain) v.stage = 3; }
            else if (v.stage == 3) v.level += (sustain - v.level) * 0.002;
            else { v.level = std::max(0.0, v.level - v.releaseStep); if (v.level <= 0) { v.stage = 0; continue; } }
            const double step = v.step;
            const double signal = wave(v.phase, step, shape);
            v.phase += step; if (v.phase >= 1) v.phase -= 1;
            v.low1 += alpha * (signal - v.low1); v.low2 += alpha * (v.low1 - v.low2);
            mixed += v.low2 * v.level * v.velocity * gain * 0.3;
        }
        // Gentle output saturation bounds simultaneous chords without clipping.
        left[i] = right[i] = float(std::tanh(mixed));
    }
}
