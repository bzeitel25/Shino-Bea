#!/usr/bin/env python3
"""
Shino & Bea — combat SFX synthesizer  (Pass 1b — de-percussed).

Fixes from Pass 1:
  * Punches/kicks no longer use a pitched sine "body" (that reads as a KICK DRUM).
    They are now dull, broadband NOISE impacts — a flesh "thwack", no pitch.
  * Katana/naginata no longer use a stack of discrete inharmonic sine partials
    (that reads as a COWBELL). They are now COMB-FILTERED NOISE "swishes" — a
    dense metallic hiss that sings like a blade, no isolated bell tones.
SNES-flavoured: 32 kHz, 16-bit, gentle bitcrush. Author short and punchy.
"""
import numpy as np
from scipy.signal import butter, sosfilt, lfilter
import os

SR = 32000

# ---------------------------------------------------------------- primitives
def t_arr(dur): return np.linspace(0, dur, int(SR*dur), endpoint=False)
def noise(dur, seed=None): return np.random.default_rng(seed).uniform(-1,1,int(SR*dur))

def env_exp(dur, tau, attack=0.004):
    n=int(SR*dur); e=np.exp(-np.arange(n)/(SR*tau)); a=int(SR*attack)
    if a>0: e[:a]*=np.linspace(0,1,a)
    return e

def env_ar(dur, attack, release):
    n=int(SR*dur); a=int(SR*attack); r=int(SR*release); e=np.ones(n)
    if a>0: e[:a]=np.linspace(0,1,a)
    if r>0: e[-r:]=np.linspace(1,0,r)
    return e

def bandpass(x, lo, hi, order=2):
    sos=butter(order,[lo/(SR/2),min(hi,SR/2-1)/(SR/2)],btype='band',output='sos'); return sosfilt(sos,x)
def lowpass(x, hi, order=2):
    sos=butter(order,min(hi,SR/2-1)/(SR/2),btype='low',output='sos'); return sosfilt(sos,x)
def highpass(x, lo, order=2):
    sos=butter(order,lo/(SR/2),btype='high',output='sos'); return sosfilt(sos,x)

def fbcomb(x, freq, g):
    """Feedback comb resonator = metallic ring, but excited by NOISE so the
    result is a dense swish (not a pure tone / bell)."""
    D=max(2,int(round(SR/float(freq)))); a=np.zeros(D+1); a[0]=1.0; a[D]=-g
    return lfilter([1.0], a, x)

def fit(a,b):
    n=max(len(a),len(b)); return (np.pad(a,(0,n-len(a))), np.pad(b,(0,n-len(b))))
def mix(*sigs):
    n=max(len(s) for s in sigs); out=np.zeros(n)
    for s in sigs: out[:len(s)]+=s
    return out
def softclip(x, drive=1.0): return np.tanh(x*drive)
def bitcrush(x, bits=12, rate_div=1):
    q=2**(bits-1); x=np.round(x*q)/q
    if rate_div>1:
        for i in range(0,len(x),rate_div): x[i:i+rate_div]=x[i]
    return x
def declick(x, ms=3):
    n=int(SR*ms/1000)
    if len(x)>2*n: x[:n]*=np.linspace(0,1,n); x[-n:]*=np.linspace(1,0,n)
    return x
def norm(x, peak=0.9):
    m=np.max(np.abs(x)); return x if m<1e-9 else x/m*peak
def finalize(x, bits=12, rate_div=1, peak=0.9):
    return norm(declick(bitcrush(x,bits,rate_div)), peak)
def sweep(f0,f1,dur,curve=1.0):
    t=np.linspace(0,1,int(SR*dur)); return f0+(f1-f0)*(t**curve)

OUT="/tmp/sfx_out"
for d in ["combat","bea","projectiles"]: os.makedirs(f"{OUT}/{d}",exist_ok=True)

# ================================================================ IMPACTS (noise, no pitch)
def punch(seed, heavy=False):
    """Dull flesh 'thwack'. Broadband noise body, NO pitched tone. Lowpassed so
    it stays a soft thud (not a bright snare/clap)."""
    np.random.seed(seed)
    if heavy:
        dur=0.16
        body = lowpass(noise(0.09,seed), 300)  * env_exp(0.09,0.035,0.001)   # low weight, no pitch
        thwack= bandpass(noise(0.07,seed+1), 220, 1100) * env_exp(0.07,0.022,0.001)
        click = highpass(noise(0.010,seed+2), 1800) * env_exp(0.010,0.003,0.0004)*0.5
        lp=2600; drive=1.7
    else:
        dur=0.12
        body = lowpass(noise(0.06,seed), 420)  * env_exp(0.06,0.020,0.001)
        thwack= bandpass(noise(0.05,seed+1), 300, 1500) * env_exp(0.05,0.015,0.0008)
        click = highpass(noise(0.008,seed+2), 2200) * env_exp(0.008,0.0025,0.0003)*0.45
        lp=3200; drive=1.5
    body,thwack=fit(body,thwack); body,click=fit(body,click)
    x=mix(body*1.0, thwack*0.85, click)
    x=lowpass(x, lp)                     # keep it a THUD, kill fizz
    return finalize(softclip(x,drive), bits=12, rate_div=1)

def kick(seed, heavy=False):
    """Airy leg whoosh -> dull noise thud. Whoosh is what separates it from a
    punch. No pitched tone."""
    np.random.seed(seed)
    if heavy:
        whd=0.14; wlo,whi=550,2400; thd=0.11; tlo=260; drive=1.6; lp=3000
    else:
        whd=0.11; wlo,whi=800,3000; thd=0.09; tlo=380; drive=1.4; lp=3400
    wh=bandpass(noise(whd,seed), wlo, whi)*env_ar(whd,0.03,0.05)
    wh*=np.linspace(0.35,1.0,len(wh))                       # swell in
    thud=lowpass(noise(thd,seed+1), tlo)*env_exp(thd,0.03 if heavy else 0.024,0.001)
    pad=int(SR*(0.055 if heavy else 0.045)); thud=np.pad(thud,(pad,0))
    wh,thud=fit(wh,thud)
    x=mix(wh*0.55, thud*1.0)
    x=lowpass(x, lp)
    return finalize(softclip(x,drive), bits=12, rate_div=1)

def crane_kick(seed):
    np.random.seed(seed); dur=0.34
    nz=noise(0.26,seed); wh=bandpass(nz,700,3000)
    trem=0.5+0.5*np.sin(2*np.pi*sweep(9,22,0.26)*t_arr(0.26))
    wh=wh*trem*env_ar(0.26,0.03,0.08); wh*=np.linspace(0.3,1.0,len(wh))
    thud=lowpass(noise(0.12,seed+1),300)*env_exp(0.12,0.03,0.001)    # noise thud, no sine
    pad=int(SR*0.20); thud=np.pad(thud,(pad,0)); wh,thud=fit(wh,thud)
    x=lowpass(mix(wh*0.6, thud*0.95), 3400)
    return finalize(softclip(x,1.4), bits=12, rate_div=1)

# ================================================================ BLADES (comb-noise swish, no bell)
def blade(seed, base, dur, tau, combs, exc_lo, exc_hi, bright_hp, g=0.9, drive=1.15, add_low=0.0):
    """Metallic swish = NOISE pushed through detuned feedback combs. Dense &
    airy (a 'shhhing'), never isolated tones (that was the cowbell)."""
    np.random.seed(seed)
    exc = bandpass(noise(dur,seed), exc_lo, exc_hi) * env_exp(dur, tau*1.4, 0.0015)
    y=np.zeros(int(SR*dur))
    for r,amp in combs:
        c=fbcomb(exc, base*r, g); y[:len(c)]+=c[:len(y)]*amp
    y=highpass(y, bright_hp)
    # bright cut transient (the 'shff' of the draw)
    tr=highpass(noise(min(0.05,dur),seed+7), max(2500,bright_hp)) * env_exp(min(0.05,dur),0.012,0.0008)
    y,tr=fit(y,tr); out=mix(y*1.0, tr*0.55)
    if add_low>0:  # naginata gets a little airy low-mid body
        lowbody=bandpass(noise(dur,seed+3), 250, 900)*env_exp(dur,tau,0.003)
        out,lowbody=fit(out,lowbody); out=mix(out, lowbody*add_low)
    out=out*env_exp(len(out)/SR, tau, 0.0015)
    return finalize(softclip(out,drive), bits=12, rate_div=1, peak=0.9)

def katana(seed, step):
    base=3000*(1.06**step)   # rises across the combo
    return blade(seed, base, 0.26, 0.085,
                 combs=[(1.0,1.0),(1.47,0.6),(2.11,0.4),(2.9,0.28)],
                 exc_lo=2400, exc_hi=9000, bright_hp=1900, g=0.9, drive=1.15)

def katana_finisher(seed):
    return blade(seed, 2850, 0.46, 0.15,
                 combs=[(1.0,1.0),(1.47,0.65),(2.11,0.45),(2.9,0.3),(3.7,0.2)],
                 exc_lo=2200, exc_hi=9500, bright_hp=1700, g=0.93, drive=1.2)

def naginata_sweep(seed):
    return blade(seed, 1750, 0.36, 0.13,
                 combs=[(1.0,1.0),(1.5,0.6),(2.1,0.4)],
                 exc_lo=1400, exc_hi=6500, bright_hp=1100, g=0.9, drive=1.2, add_low=0.35)

def naginata_spin(seed):
    np.random.seed(seed); dur=0.44
    swish=blade(seed,1650,dur,0.16,[(1.0,1.0),(1.5,0.6),(2.1,0.38)],1300,6000,1000,g=0.92,drive=1.15,add_low=0.3)
    trem=0.6+0.4*np.sin(2*np.pi*sweep(7,15,dur)*t_arr(dur))
    swish,tr=fit(swish, trem); return finalize(swish*tr, bits=12, rate_div=1)

def naginata_thrust(seed):
    np.random.seed(seed)
    wh=bandpass(noise(0.09,seed),900,3400)*env_exp(0.09,0.02,0.001); wh*=np.linspace(0.6,1.0,len(wh))
    ring=blade(seed,1500,0.14,0.05,[(1.0,1.0),(1.5,0.5)],1400,6000,1200,g=0.85,drive=1.1)
    thud=lowpass(noise(0.09,seed+2),320)*env_exp(0.09,0.025,0.001)
    pad=int(SR*0.05); thud=np.pad(thud,(pad,0)); ring=np.pad(ring,(pad,0))
    wh,thud=fit(wh,thud); wh,ring=fit(wh,ring)
    return finalize(softclip(mix(wh*0.6,thud*0.8,ring*0.7),1.4), bits=12, rate_div=1)

def naginata_overhead(seed):
    np.random.seed(seed)
    wh=bandpass(noise(0.16,seed),500,2600)*env_ar(0.16,0.04,0.05); wh*=np.linspace(0.3,1.0,len(wh))
    slam=lowpass(noise(0.16,seed+1),240)*env_exp(0.16,0.05,0.001)     # heavy noise slam, no pitch
    ring=blade(seed,1450,0.20,0.09,[(1.0,1.0),(1.5,0.55)],1200,6000,1100,g=0.9,drive=1.1)
    pad=int(SR*0.10); slam=np.pad(slam,(pad,0)); ring=np.pad(ring,(pad,0))
    wh,slam=fit(wh,slam); wh,ring=fit(wh,ring)
    x=lowpass(mix(wh*0.5, slam*1.0, ring*0.6), 4200)
    return finalize(softclip(x,1.6), bits=12, rate_div=1, peak=0.95)

# ================================================================ PROJECTILES
def ki_blast_hit(seed):
    """Energy zap — ring-mod is intentional here (sci-fi), Bruno didn't flag it,
    but soften the crush a touch."""
    np.random.seed(seed); dur=0.22
    carrier=np.sin(2*np.pi*np.cumsum(sweep(900,300,dur))/SR)
    modf=np.sin(2*np.pi*np.cumsum(sweep(120,40,dur))/SR)
    energy=carrier*(0.5+0.5*modf)*env_exp(dur,0.05,0.004)
    zap=bandpass(noise(0.07,seed),1500,5000)*env_exp(0.07,0.015,0.001)
    x=mix(energy*0.8, zap*0.5)
    return finalize(softclip(x,1.35), bits=10, rate_div=2)

def kamehameha_fire(seed):
    np.random.seed(seed); dur=0.55
    vib=1.0+0.02*np.sin(2*np.pi*7*t_arr(dur))
    ph=np.cumsum(sweep(160,300,dur)*vib)/SR
    body=lowpass(2*((ph)%1.0)-1, 2600)*env_ar(dur,0.12,0.18)
    ring=np.sin(2*np.pi*np.cumsum(sweep(300,520,dur))/SR)*(0.5+0.5*np.sin(2*np.pi*70*t_arr(dur)))*env_ar(dur,0.15,0.2)
    breath=bandpass(noise(dur,seed),800,4000)*env_ar(dur,0.1,0.2)*0.4
    body,ring=fit(body,ring); body,breath=fit(body,breath)
    return finalize(softclip(mix(body*0.7,ring*0.5,breath),1.3), bits=10, rate_div=2, peak=0.9)

def shino_ai_fire(seed):
    np.random.seed(seed); dur=0.2
    ph=np.cumsum(sweep(200,340,dur))/SR
    body=lowpass(2*(ph%1.0)-1,2400)*env_exp(dur,0.05,0.01)
    ring=np.sin(2*np.pi*np.cumsum(sweep(360,540,dur))/SR)*env_exp(dur,0.05,0.01)
    body,ring=fit(body,ring)
    return finalize(softclip(mix(body*0.6,ring*0.5),1.2), bits=10, rate_div=2)

def kunai_hit(seed):
    """Short metallic 'tink' via a brief bright comb-swish — crisp, not a bonk."""
    return blade(seed, 3600, 0.11, 0.035,
                 combs=[(1.0,1.0),(1.6,0.5)], exc_lo=3000, exc_hi=10000,
                 bright_hp=2600, g=0.82, drive=1.1)

def kunai_throw(seed):
    np.random.seed(seed); dur=0.13
    wh=bandpass(noise(dur,seed),1400,5200)*env_ar(dur,0.015,0.05); wh*=np.linspace(0.5,1.0,len(wh))
    whistle=np.sin(2*np.pi*np.cumsum(sweep(3200,1800,dur))/SR)*env_exp(dur,0.03,0.004)*0.22
    wh,whistle=fit(wh,whistle)
    return finalize(softclip(mix(wh*0.7,whistle),1.1), bits=12, rate_div=1)

# ================================================================ RENDER
def write_wav(path,x):
    x=np.clip(x,-1,1); pcm=(x*32767).astype('<i2')
    import wave
    with wave.open(path,'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())

jobs=[
    ("combat/hit_light_01.wav", punch(11)),
    ("combat/hit_light_02.wav", punch(22)),
    ("combat/hit_light_03.wav", punch(33)),
    ("combat/hit_heavy_01.wav", punch(41,heavy=True)),
    ("combat/hit_heavy_02.wav", punch(52,heavy=True)),
    ("combat/kick_light_01.wav", kick(61)),
    ("combat/kick_light_02.wav", kick(72)),
    ("combat/kick_light_03.wav", kick(83)),
    ("combat/kick_heavy_01.wav", kick(91,heavy=True)),
    ("combat/kick_heavy_02.wav", kick(102,heavy=True)),
    ("combat/crane_kick_01.wav", crane_kick(111)),
    ("combat/crane_kick_02.wav", crane_kick(122)),
    ("bea/bea_katana_1.wav", katana(201,0)),
    ("bea/bea_katana_2.wav", katana(202,1)),
    ("bea/bea_katana_3.wav", katana(203,2)),
    ("bea/bea_katana_4.wav", katana(204,3)),
    ("bea/bea_katana_finisher.wav", katana_finisher(210)),
    ("bea/bea_naginata_sweep_01.wav", naginata_sweep(221)),
    ("bea/bea_naginata_sweep_02.wav", naginata_sweep(232)),
    ("bea/bea_naginata_spin.wav", naginata_spin(241)),
    ("bea/bea_naginata_thrust_1.wav", naginata_thrust(251)),
    ("bea/bea_naginata_overhead_slam.wav", naginata_overhead(261)),
    ("projectiles/ki_blast_hit_01.wav", ki_blast_hit(301)),
    ("projectiles/ki_blast_hit_02.wav", ki_blast_hit(312)),
    ("projectiles/ki_blast_hit_03.wav", ki_blast_hit(323)),
    ("projectiles/kamehameha_fire.wav", kamehameha_fire(330)),
    ("projectiles/shino_ai_fire.wav", shino_ai_fire(340)),
    ("projectiles/kunai_hit_01.wav", kunai_hit(351)),
    ("projectiles/kunai_hit_02.wav", kunai_hit(362)),
    ("projectiles/kunai_hit_03.wav", kunai_hit(373)),
    ("projectiles/kunai_throw_01.wav", kunai_throw(381)),
    ("projectiles/kunai_throw_02.wav", kunai_throw(392)),
]
for name,data in jobs:
    write_wav(f"{OUT}/{name}", data)
    print(f"{name:44s} {int(len(data)/SR*1000):4d}ms")
print(f"\n{len(jobs)} files written")
