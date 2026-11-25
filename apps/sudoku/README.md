# Sudoku: eraser helper

`backend/eraser.c` is the source of `backend/entry` in the `sudoku` package. The tablet hands the
Marker to AppLoad apps as a plain mouse, so the app cannot tell the eraser end from the tip. The
helper watches the Marker's input device for the "eraser in range" key and passes that one bit to
the app. It never grabs the device and never writes to it.

Build: `aarch64-linux-gnu-gcc -O2 -static -o entry eraser.c && aarch64-linux-gnu-strip entry`
