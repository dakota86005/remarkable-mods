# Sudoku: pen helper

`backend/helper.c` is the source of `backend/entry` in the `sudoku` package. The tablet hands the
Marker to AppLoad apps as a plain mouse, so the app cannot tell the eraser end from the tip, and
when the board is drawn by the tablet's own pen engine (the Notebook ink setting) the app gets no
pen events at all. The helper watches the Marker's input device and passes the app which end is in
use, whether the Marker is near the screen (for palm rejection), where each stroke starts, and the finished stroke. It never grabs the device and never writes
to it.

Build: `aarch64-linux-gnu-gcc -O2 -static -o entry helper.c && aarch64-linux-gnu-strip entry`
