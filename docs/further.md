# 7. Going further

You now have the skeleton of any real-time FPGA audio project: a codec at an exact sample rate, a
method for writing DSP that is correct to the bit, a time-shared processing chain, and a control path
from Linux. Some directions to take it, roughly from easiest to hardest.

## More effects

The repository has 10 more effects built the way part 2 describes; read them in this order, each adds
one idea:

1. `booster.vhd`: combinational, no state.
2. `delay.vhd`: block RAM, circular buffer, a one-pole low-pass in the feedback path.
3. `drive.vhd`: distortion and overdrive from one entity with a generic; filters before and after a
   saturating non-linearity, like the analog circuits.
4. `phaser.vhd`: all-pass filters swept by an LFO.
5. `moddelay.vhd`: chorus and flanger, a delay line whose length an LFO modulates, with linear
   interpolation between samples.
6. `reverb.vhd`: Freeverb, 8 comb filters and 4 all-pass filters, many delay lines in block RAM.
7. `cab.vhd`: a 512-tap FIR filter computed one tap per clock cycle.

**Study next:** Udo Zölzer (ed.), *DAFX: Digital Audio Effects*, 2nd ed., Wiley, 2011, has every one
of these effects and many more; Julius O. Smith's online books
([ccrma.stanford.edu/~jos](https://ccrma.stanford.edu/~jos/)) cover filters and reverbs in depth.

## Better sound

- **Aliasing in the distortion.** A hard clipper creates harmonics above the Nyquist frequency
  (24 kHz), which fold back as inharmonic tones. *Oversampling* (run the non-linearity at 4× the rate,
  filter, decimate) fixes it, and the cycle budget has room for it.
- **24 bits all the way.** The effects work at 16 bits; the codec gives 24. Widening the path improves
  the noise floor of quiet, high-gain settings. The M10K and DSP blocks handle 18 and 27 bits natively.
- **Real cabinet impulse responses.** `cab.vhd` uses fixed coefficients. Loading an impulse response
  (a WAV) from Linux into the coefficient RAM would make the cabinet selectable.

## Better hardware/software interface

- **A kernel driver instead of `/dev/mem`.** Mapping physical memory needs root and lets any bug in
  user space write anywhere. A small platform driver that owns the register range, matched through the
  device tree, and exposes a character device or sysfs attributes is the proper way. The course covers
  it in [Device Driver](https://insper.github.io/Embarcados-Avancados/Tutorial-HPS-DeviceDriver/) and
  [Kernel driver for an FPGA LED](https://insper.github.io/Embarcados-Avancados/Tutorial-HPS-FPGA-kernel-char-led-driver/).
- **Interrupts.** The tuner polls the `done` bit. An FPGA-to-HPS interrupt (the HPS has 64 of them
  from the FPGA) and a driver that sleeps until it fires would use no CPU while waiting.
- **Long recordings with the FPGA-to-SDRAM port.** On-chip RAM limits the delay to about a second.
  The HPS's DDR3 (1 GB) is reachable from the FPGA through the FPGA-to-SDRAM ports; with it you can
  build a looper with minutes of audio.

## Other ways to write the DSP

- **High-level synthesis.** The course's [HLS tutorial](https://insper.github.io/Embarcados-Avancados/Tutorial-Acelerando-HLS/)
  turns C++ into hardware. Writing one of these effects in HLS and comparing area and latency with the
  hand-written VHDL is a good experiment.
- **DSP Builder / MATLAB HDL Coder** generate fixed-point hardware from models, the industrial version
  of the Python-model method used here.

## References

- Cirrus Logic, [*WM8731 / WM8731L datasheet*](https://statics.cirrus.com/pubs/proDatasheet/WM8731_v4.9.pdf), rev. 4.9.
- Terasic, *DE10-Standard User Manual* and *System CD* (GHRD, pin assignments), [terasic.com.tw](https://www.terasic.com.tw/).
- Intel, [*Avalon Interface Specifications*](https://www.intel.com/content/www/us/en/docs/programmable/683091/current/introduction-to-the-interface-specifications.html).
- Intel, *Cyclone V Hard Processor System Technical Reference Manual*, chapter "HPS-FPGA Bridges".
- Intel, *Quartus Prime Timing Analyzer User Guide*, section on multicycle exceptions.
- NXP, [*UM10204: I²C-bus specification and user manual*](https://www.nxp.com/docs/en/user-guide/UM10204.pdf).
- Philips, *I²S bus specification*, 1986 (and the WM8731 datasheet for the left-justified variant).
- A. de Cheveigné and H. Kawahara, "YIN, a fundamental frequency estimator for speech and music",
  *J. Acoust. Soc. Am.* 111(4), 2002.
- U. Zölzer (ed.), *DAFX: Digital Audio Effects*, 2nd ed., Wiley, 2011.
- Course tutorials: [Embarcados Avançados](https://insper.github.io/Embarcados-Avancados/), especially
  *Blink FPGA LED from HPS*, *NIOS IP*, *Setup* (build system) and the 2020 student tutorial
  [*Audio na DE10*](https://insper.github.io/Embarcados-Avancados/2020/Audio/).
