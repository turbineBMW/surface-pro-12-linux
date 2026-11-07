project('sp12-autoframe', 'cpp',
  version: '0.1',
  default_options: ['cpp_std=c++17', 'warning_level=2', 'buildtype=release'])

gst_dep = dependency('gstreamer-1.0')
gstvideo_dep = dependency('gstreamer-video-1.0')
openvino_dep = dependency('openvino')
opencv_dep = dependency('opencv5')

plugin_dir = get_option('libdir') / 'gstreamer-1.0'

shared_library('gstsp12autoframe',
  ['src/gstsp12autoframe.cpp', 'src/gstsp12bt601.cpp', 'src/yunet.cpp'],
  dependencies: [gst_dep, gstvideo_dep, openvino_dep, opencv_dep],
  install: true,
  install_dir: plugin_dir,
  name_prefix: '')
