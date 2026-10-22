#!/usr/bin/env python3
"""Build original playable Surge patches from its CC0 init templates (no audio samples)."""
import copy
import math
from pathlib import Path
import struct
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
TEMPLATES = Path('/Library/Application Support/Surge XT/patches_factory/Templates')
OUTPUT = ROOT / 'Resources' / 'SketchpadPulse'

def template(name):
    data = (TEMPLATES / f'Init {name}.fxp').read_bytes()
    size = struct.unpack_from('<I', data, 64)[0]
    root = ET.fromstring(data[92:92 + size])
    assert 'CC0' in root.find('meta').get('license', '')
    return root

def make(number, name, base, settings, routes=()):
    root = copy.deepcopy(template(base))
    root.find('meta').attrib.update(name=name, category='Sketchpad Pulse', author='AI Music Sketchpad',
        comment='Original reference-inspired synthesis; not a sample or exact transcription. All keys playable. Mod wheel opens tone.')
    parameters = {node.tag: node for node in root.find('parameters')}
    common = dict(volume=-6, scenemode=0, polylimit=16, a_polymode=0, a_octave=0,
                  a_vca_velsense=-12, a_env1_attack=-8, a_env1_decay=math.log2(.3),
                  a_env1_sustain=.25, a_env1_release=math.log2(.12),
                  a_env2_attack=-8, a_env2_decay=math.log2(.2), a_env2_sustain=0,
                  a_env2_release=math.log2(.1), a_osc1_keytrack=1, a_osc1_retrigger=1,
                  a_filter1_keytrack=.6, a_drift=.03)
    common.update(settings)
    for key, value in common.items():
        assert key in parameters, key
        parameters[key].set('value', str(value))
        for child in list(parameters[key]): parameters[key].remove(child)
    for key, source, depth in routes:
        ET.SubElement(parameters[key], 'modrouting', source=str(source), depth=str(depth), muted='0', source_index='0')
    # Do not ship the template author's DAW/editor state or sequence settings.
    for tag in ('dawExtraState', 'stepsequences', 'msegs', 'formulae'):
        node = root.find(tag)
        if node is not None: root.remove(node)
    xml = ET.tostring(root, encoding='utf-8', xml_declaration=True)
    chunk = b'sub3' + struct.pack('<I', len(xml)) + bytes(24) + xml
    title = name.encode()[:27].ljust(28, b'\0')
    header = b'CcnK' + struct.pack('>I', len(chunk) + 52) + b'FPCh' + struct.pack('>I', 1)
    header += b'cjs3' + struct.pack('>II', 1, 1) + title + struct.pack('>I', len(chunk))
    (OUTPUT / f'{number:02d} {name}.fxp').write_bytes(header + chunk)

OUTPUT.mkdir(parents=True, exist_ok=True)
make(1, 'Deep Pulse Kick', 'Sine', dict(a_env1_decay=math.log2(.48), a_env1_sustain=0,
     a_env1_release=math.log2(.2), a_env2_decay=math.log2(.035), a_filter1_keytrack=0),
     [('a_osc1_pitch', 16, 24)])
make(2, 'Round Sub', 'Sine', dict(a_env1_attack=math.log2(.008), a_env1_decay=math.log2(.5),
     a_env1_sustain=.72, a_env1_release=math.log2(.18), a_drift=0))
make(3, 'Rolling Harmonic Bass', 'Saw', dict(a_filter1_type=1, a_filter1_cutoff=-20,
     a_filter1_resonance=.22, a_filter1_envmod=34, a_env1_sustain=.28,
     a_env1_decay=math.log2(.28), a_env2_decay=math.log2(.17)), [('a_filter1_cutoff', 6, 28)])
make(4, 'Resonant Pulse Pluck', 'Saw', dict(a_filter1_type=1, a_filter1_cutoff=-7,
     a_filter1_resonance=.5, a_filter1_envmod=28, a_env1_decay=math.log2(.38),
     a_env1_sustain=0, a_env1_release=math.log2(.22), a_env2_decay=math.log2(.12)),
     [('a_filter1_cutoff', 6, 22)])
make(5, 'Metal Tick', 'Sine', dict(a_mute_noise=0, a_level_noise=.38, a_noisecol=.7,
     a_fm_switch=1, a_fm_depth=-4, a_osc2_type=1, a_osc2_octave=3, a_osc2_pitch=1.7,
     a_filter1_type=4, a_filter1_cutoff=28, a_filter1_keytrack=.3, a_filter1_resonance=.22,
     a_env1_decay=math.log2(.085), a_env1_sustain=0, a_env1_release=math.log2(.06)),
     [('a_filter1_cutoff', 6, 15)])
make(6, 'Air Shaker', 'Sine', dict(a_mute_o1=1, a_mute_noise=0, a_level_noise=.65,
     a_noisecol=.5, a_filter1_type=4, a_filter1_cutoff=34, a_filter1_keytrack=.35,
     a_filter1_resonance=.12, a_env1_attack=math.log2(.009), a_env1_decay=math.log2(.17),
     a_env1_sustain=0, a_env1_release=math.log2(.08)), [('a_filter1_cutoff', 6, 12)])
print(f'Built six original patches in {OUTPUT}')
