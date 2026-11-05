# Hardware ISP (IPU7.5 PSYS) userspace

Work towards running the Surface Pro 12 cameras through Intel's PSYS with
Intel's Linux camera HAL, using the graph settings and tuning files from the
Windows driver. Plan and findings: `docs/hardware-isp-plan.md`. The kernel
side is `dkms/psys/`.

Nothing here contains Windows data. The Windows files live under `private/`
and are converted at build time.

## tools/

- `stamp-hashes.py <win.bin> <out.bin>`: stamp a Windows IPU75XA graph
  settings file with the hash codes of ipu7-camera-hal e5172cc (the release
  whose binary layout the Windows PTL files share).
- `linuxize-100002` (C++): rewrite the graph-100002 settings for the in-tree
  ISYS, which writes unpacked 16-bit RAW10 lines where Windows' ISYS wrote
  25 pixels per 32 bytes. Build with the HAL's `modules/ipu_desc/ipu75xa`
  headers and `kernel_meta.h` from `gen-kernel-meta.py`:
  `g++ -std=c++17 -w -DIPU_SYSVER_ipu75 -DGRC_IPU75XA -I<ipu75xa> -I<meta dir> linuxize-100002.cpp`.
- `check-graph`, `graph-pick`, `graph-dump` (C++): load a graph file with the
  HAL's own reader and resolve every setting; show which graph the HAL's
  query key picks; dump one setting's 100002 block (input feeder words,
  links). `check-graph` and `graph-pick` also link
  `Ipu75xaStaticGraphReaderAutogen.cpp` and `Ipu75xaStaticGraphAutogen.cpp`.
- `graph-settings-info.py`, `aiqb-laiq-versions.py`: quick looks at a graph
  file (sensor modes, output pins) and a CPFF `.aiqb` (LAIQ record versions).
- `ov13858-modes.py`: register tables of Windows' `ov13858.sys` (16-byte
  entries), for the 4076x2806 mode.
- `gen-kernel-meta.py`: from Marco Glauser's galaxybook6-ultra-camera
  (GPL-2.0), emits the per-node kernel tables the C++ tools use.

## config/sensors/

HAL sensor profiles `imx681-uf.json` and `ov13858-wf.json` (from Intel's
templates, with the `Intel IPU7.5` entity names the ipu6 driver uses).

## patches/

- `hal-aic-timestamp.patch`: set the mandatory AIC input timestamp (Glauser).
- `hal-arch-jsoncpp.patch`: Arch's `<json/json.h>` include path (AUR).
- `hal-zoom-region.patch`: the HAL's pan-tilt-zoom path (an ISP-side crop
  through the output scalers) made to work: the zoom region copied into the
  per-request context, a window centred on one axis no longer treated as a
  centred zoom, and the 1:1-window cropper cropping at the region instead of
  the centre. For automatic framing (`docs/auto-framing-plan.md`, stage 3).
- `icamerasrc-zoom-region.patch`: icamerasrc `zoom-region` property
  (`"left,top,right,bottom"` in sensor active-array pixels, live). The
  PKGBUILD applies `hal-*.patch` to the HAL and `icamerasrc-*.patch` to
  icamerasrc.

## build-package.sh, install-hal-package.sh

The real thing: `build-package.sh` stages the inputs makepkg cannot fetch
(the pinned checkouts, `patches/`, `config/sensors/`, the converted graphs,
the Windows tuning files, the relay configuration) into
`pkg/sp12-camera-hal/private/` (gitignored) and runs makepkg;
`install-hal-package.sh` (root) installs the result together with
`sp12-flex-tools`, removing the copies the dev installer left under /etc.
The package stays local because of the Windows-derived files.

## build-dev.sh, run-dev.sh

Dev build of HAL + icamerasrc + closed libraries into
`private/camera/psys/work/prefix`, and a short capture from it.
