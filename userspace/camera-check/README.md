# Camera Check

A small page that shows a camera and measures what the browser decodes:
black and white level, mean level, saturation, and the colour of a region
you drag on the picture (a white wall, a face). It is what Meet, Teams and
Zoom get in Chromium, so use it instead of Snapshot to judge colour:
Snapshot 51 (GTK 4.24, gtk4paintablesink 0.15.4) shows the limited-range
stream as full range, which looks grey and flat; Chromium decodes it
correctly.

    python3 userspace/camera-check/serve.py      # http://127.0.0.1:8765
    chromium http://127.0.0.1:8765/              # "Install" makes it a PWA

`getUserMedia` needs a secure origin, so it is served from 127.0.0.1.

Scripted measurement (no UI): `index.html?auto=SECONDS&label=TEXT&roi=x,y,w,h`
picks the first camera whose label contains TEXT, measures the region (0..1
of the frame) and POSTs the numbers to `/result` once a second; `serve.py`
prints them as JSON lines. For example, with the server running:

    chromium --headless=new --user-data-dir=/tmp/cc --use-fake-ui-for-media-stream \
      "http://127.0.0.1:8765/index.html?auto=12&label=front%20camera%20isp&roi=0.72,0.25,0.12,0.15"
