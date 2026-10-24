#include "SketchSynthDSP.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <mach/mach_time.h>
#include <vector>

namespace {
struct SequenceNote { double start, end; uint8_t pitch, velocity; };
struct SequenceEvent { double seconds; uint8_t pitch, velocity; bool on; };
struct Region { double start, end; };
struct Sequence {
    AudioUnit unit;
    double bpm, tickSeconds;
    std::vector<SequenceNote> notes;
    std::vector<SequenceEvent> events;
    std::vector<Region> regions;
    // Single control-thread writer, render-thread reader. Odd revisions are in progress.
    std::atomic<uint64_t> revision{0}, anchor{0};
    std::atomic<double> from{0}, rate{48000};
    std::atomic<bool> enabled{false};
    uint64_t appliedRevision = 0;
    size_t cursor = 0;
    int held[128]{};
    double seconds = 0, renderRate = 48000, renderFrom = 0;
    bool active = false, chase = false, changed = false;
    explicit Sequence(AudioUnit u, double tempo) : unit(u), bpm(tempo) {
        mach_timebase_info_data_t timebase{};
        mach_timebase_info(&timebase);
        tickSeconds = double(timebase.numer) / timebase.denom / 1e9;
    }
    void panic() {
        MusicDeviceMIDIEvent(unit, 0xB0, 64, 0, 0);
        MusicDeviceMIDIEvent(unit, 0xB0, 123, 0, 0);
        MusicDeviceMIDIEvent(unit, 0xB0, 120, 0, 0);
        std::fill(std::begin(held), std::end(held), 0);
    }
    void send(const SequenceEvent &event, UInt32 offset) {
        if (event.on) {
            ++held[event.pitch];
            MusicDeviceMIDIEvent(unit, 0x90, event.pitch, event.velocity, offset);
        } else if (held[event.pitch] > 0 && --held[event.pitch] == 0) {
            MusicDeviceMIDIEvent(unit, 0x80, event.pitch, 0, offset);
        }
    }
    static OSStatus render(void *context, AudioUnitRenderActionFlags *flags,
                           const AudioTimeStamp *stamp, UInt32, UInt32 frames, AudioBufferList *data) {
        auto &s = *static_cast<Sequence *>(context);
        if (*flags & kAudioUnitRenderAction_PreRender) {
            auto rev = s.revision.load();
            s.active = false;
            if (rev & 1) return noErr; // Never spin or block the audio thread.
            auto anchor = s.anchor.load();
            auto from = s.from.load();
            auto rate = s.rate.load();
            auto enabled = s.enabled.load();
            if (rev != s.revision.load()) return noErr;
            s.renderRate = rate;
            s.renderFrom = from;
            s.seconds = anchor ? (double(stamp->mHostTime) - double(anchor)) * s.tickSeconds + from
                               : stamp->mSampleTime / rate + from;
            if (rev != s.appliedRevision) {
                s.panic(); s.chase = true; s.changed = true; s.appliedRevision = rev;
            }
            double end = s.seconds + frames / rate;
            s.active = enabled && end > from;
            if (!s.active) return noErr;
            double start = std::max(from, s.seconds);
            if (s.chase) {
                s.cursor = std::lower_bound(s.events.begin(), s.events.end(), start,
                    [](const SequenceEvent &event, double time) { return event.seconds < time; }) - s.events.begin();
                UInt32 offset = UInt32(std::max(0.0, std::round((start - s.seconds) * rate)));
                for (const auto &note : s.notes) {
                    if (note.start < start && note.end > start)
                        s.send({start, note.pitch, note.velocity, true}, offset);
                }
                s.chase = false;
            }
            while (s.cursor < s.events.size() && s.events[s.cursor].seconds < end) {
                const auto &event = s.events[s.cursor++];
                UInt32 offset = UInt32(std::clamp(std::round((event.seconds - s.seconds) * rate), 0.0, double(frames - 1)));
                s.send(event, offset);
            }
        } else if ((*flags & kAudioUnitRenderAction_PostRender) && data) {
            if (!s.active) {
                for (UInt32 b = 0; b < data->mNumberBuffers; ++b)
                    if (data->mBuffers[b].mData) std::memset(data->mBuffers[b].mData, 0, data->mBuffers[b].mDataByteSize);
                return noErr;
            }
            // Retain clip boundaries (including silence between clips), not unlimited AU tails.
            auto region = std::lower_bound(s.regions.begin(), s.regions.end(), s.seconds,
                [](const Region &r, double t) { return r.end <= t; });
            for (UInt32 frame = 0; frame < frames; ++frame) {
                double time = s.seconds + frame / s.renderRate;
                while (region != s.regions.end() && region->end <= time) ++region;
                if (time >= s.renderFrom && region != s.regions.end() && time >= region->start) continue;
                for (UInt32 b = 0; b < data->mNumberBuffers; ++b) {
                    auto &buffer = data->mBuffers[b];
                    size_t first = size_t(frame) * buffer.mNumberChannels;
                    if (buffer.mData && (first + buffer.mNumberChannels) * sizeof(float) <= buffer.mDataByteSize)
                        std::fill_n(static_cast<float *>(buffer.mData) + first, buffer.mNumberChannels, 0.f);
                }
            }
        }
        return noErr;
    }
    static OSStatus tempo(void *p, Float64 *beat, Float64 *tempo) {
        auto &s = *static_cast<Sequence *>(p);
        if (beat) *beat = std::max(0.0, s.seconds) * s.bpm / 60;
        if (tempo) *tempo = s.bpm;
        return noErr;
    }
    static OSStatus musical(void *p, UInt32 *next, Float32 *numerator, UInt32 *denominator, Float64 *downbeat) {
        auto &s = *static_cast<Sequence *>(p);
        double beat = std::max(0.0, s.seconds) * s.bpm / 60;
        if (next) *next = UInt32(std::round((std::ceil(beat) - beat) * 60 / s.bpm * s.renderRate));
        if (numerator) *numerator = 4;
        if (denominator) *denominator = 4;
        if (downbeat) *downbeat = std::floor(beat / 4) * 4;
        return noErr;
    }
    static OSStatus transport(void *p, Boolean *playing, Boolean *changed, Float64 *sample,
                              Boolean *cycling, Float64 *start, Float64 *end) {
        auto &s = *static_cast<Sequence *>(p);
        if (playing) *playing = s.active;
        if (changed) { *changed = s.changed; s.changed = false; }
        if (sample) *sample = std::max(0.0, s.seconds) * s.renderRate;
        if (cycling) *cycling = false;
        if (start) *start = 0;
        if (end) *end = 0;
        return noErr;
    }
};
static_assert(std::atomic<double>::is_always_lock_free && std::atomic<uint64_t>::is_always_lock_free);
}
extern "C" SketchSequenceRef SketchSequenceCreate(AudioUnit unit, double bpm) {
    if (!unit || !std::isfinite(bpm) || bpm <= 0) return nullptr;
    auto *s = new Sequence(unit, bpm);
    HostCallbackInfo callbacks{s, Sequence::tempo, Sequence::musical, Sequence::transport, nullptr};
    if (AudioUnitSetProperty(unit, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global, 0, &callbacks, sizeof(callbacks)) != noErr
        || AudioUnitAddRenderNotify(unit, Sequence::render, s) != noErr) {
        HostCallbackInfo empty{};
        AudioUnitSetProperty(unit, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global, 0, &empty, sizeof(empty));
        delete s; return nullptr;
    }
    return s;
}
extern "C" void SketchSequenceDestroy(SketchSequenceRef ref) {
    auto *s = static_cast<Sequence *>(ref);
    if (!s) return;
    AudioUnitRemoveRenderNotify(s->unit, Sequence::render, s);
    HostCallbackInfo empty{};
    AudioUnitSetProperty(s->unit, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global, 0, &empty, sizeof(empty));
    delete s;
}
extern "C" void SketchSequenceAddNote(SketchSequenceRef ref, double start, double end, uint8_t pitch, uint8_t velocity) {
    if (std::isfinite(start) && std::isfinite(end) && end > start && pitch < 128 && velocity > 0)
        static_cast<Sequence *>(ref)->notes.push_back({start, end, pitch, velocity});
}
extern "C" void SketchSequenceAddRegion(SketchSequenceRef ref, double start, double end) {
    if (std::isfinite(start) && std::isfinite(end) && end > start)
        static_cast<Sequence *>(ref)->regions.push_back({start, end});
}
extern "C" void SketchSequencePrepare(SketchSequenceRef ref) {
    auto &s = *static_cast<Sequence *>(ref);
    s.events.clear(); s.events.reserve(s.notes.size() * 2);
    for (const auto &n : s.notes) {
        s.events.push_back({n.start, n.pitch, n.velocity, true});
        s.events.push_back({n.end, n.pitch, 0, false});
    }
    std::stable_sort(s.events.begin(), s.events.end(), [](const auto &a, const auto &b) {
        return a.seconds == b.seconds ? a.on < b.on : a.seconds < b.seconds;
    });
    std::sort(s.regions.begin(), s.regions.end(), [](const auto &a, const auto &b) { return a.start < b.start; });
    std::vector<Region> merged;
    for (auto r : s.regions) {
        if (!merged.empty() && r.start <= merged.back().end) merged.back().end = std::max(r.end, merged.back().end);
        else merged.push_back(r);
    }
    s.regions = std::move(merged);
}
extern "C" void SketchSequenceStart(SketchSequenceRef ref, uint64_t anchor, double from, double rate) {
    auto &s = *static_cast<Sequence *>(ref);
    s.revision.fetch_add(1); s.anchor.store(anchor); s.from.store(from); s.rate.store(rate);
    s.enabled.store(true); s.revision.fetch_add(1);
}
extern "C" void SketchSequenceStop(SketchSequenceRef ref) {
    auto &s = *static_cast<Sequence *>(ref);
    s.revision.fetch_add(1); s.enabled.store(false); s.revision.fetch_add(1);
}
