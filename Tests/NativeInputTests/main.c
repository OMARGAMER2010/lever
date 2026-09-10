#include "LeverInputState.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

int main(void) {
    LeverInputState state;
    LeverInputInit(&state);
    state.captured = true;
    LeverInputMotion(&state, 2, -3);
    LeverInputFrame frame = LeverInputSample(&state, 1.0 / 60.0);
    assert(frame.axes[2] > 0 && frame.axes[3] < 0);
    int slow = frame.axes[2];
    LeverInputReset(&state);
    state.captured = true;
    LeverInputMotion(&state, 4, -6);
    frame = LeverInputSample(&state, 1.0 / 60.0);
    assert(frame.axes[2] > slow);

    LeverInputReset(&state);
    state.captured = true;
    state.invertY = true;
    LeverInputMotion(&state, 10000, -10000);
    frame = LeverInputSample(&state, 1.0 / 60.0);
    assert(frame.axes[2] > 0 && frame.axes[3] > 0);
    assert(hypot(frame.axes[2], frame.axes[3]) <= 32768);
    for (int i = 0; i < 10; ++i) frame = LeverInputSample(&state, 1.0 / 60.0);
    assert(frame.axes[2] == 0 && frame.axes[3] == 0);

    state.directionKeys[0] = 13;
    state.directionKeys[3] = 2;
    state.buttonKeys[0] = 49;
    LeverInputSetKey(&state, 13, true);
    LeverInputSetKey(&state, 2, true);
    LeverInputSetKey(&state, 49, true);
    LeverInputSetMouseButton(&state, 1, true);
    frame = LeverInputSample(&state, 1.0 / 60.0);
    assert(frame.axes[0] > 0 && frame.axes[1] < 0 && frame.buttons[0] == 1);
    assert(hypot(frame.axes[0], frame.axes[1]) <= 32768);
    assert(frame.axes[4] == 32767);
    LeverInputReset(&state);
    frame = LeverInputSample(&state, 1.0 / 60.0);
    for (int i = 0; i < 4; ++i) assert(frame.axes[i] == 0);
    assert(frame.axes[4] == -32768 && frame.axes[5] == -32768);
    for (int i = 0; i < 15; ++i) assert(frame.buttons[i] == 0);
    assert(state.directionKeys[0] == 13 && state.invertY);

    // Un toque que termina entre dos consultas SDL también debe llegar al juego.
    LeverInputSetKey(&state, 49, true);
    LeverInputSetKey(&state, 49, false);
    frame = LeverInputSample(&state, 1.0 / 120.0);
    assert(frame.buttons[0] == 1);
    for (int i = 0; i < 8; ++i) frame = LeverInputSample(&state, 1.0 / 120.0);
    assert(frame.buttons[0] == 0);
    LeverInputSetKey(&state, 49, true);
    for (int i = 0; i < 8; ++i) frame = LeverInputSample(&state, 1.0 / 120.0);
    LeverInputSetKey(&state, 49, true);
    LeverInputSetKey(&state, 49, false);
    frame = LeverInputSample(&state, 1.0 / 120.0);
    assert(frame.buttons[0] == 0); // La repetición del teclado no prolonga la liberación.
    LeverInputSetKey(&state, 49, true);
    LeverInputReset(&state);
    frame = LeverInputSample(&state, 1.0 / 120.0);
    assert(frame.buttons[0] == 0);

    state.captured = true;
    LeverInputSetMouseButton(&state, 0, true);
    LeverInputSetMouseButton(&state, 0, false);
    LeverInputSetMouseButton(&state, 1, true);
    LeverInputSetMouseButton(&state, 1, false);
    frame = LeverInputSample(&state, 1.0 / 120.0);
    assert(frame.buttons[2] == 1 && frame.axes[4] == 32767);
    LeverInputReset(&state);
    frame = LeverInputSample(&state, 1.0 / 120.0);
    assert(frame.buttons[2] == 0 && frame.axes[4] == -32768);
    state.captured = true;
    LeverInputSetKey(&state, 49, true);
    LeverInputSetKey(&state, 49, false);
    LeverInputSetMouseButton(&state, 0, true);
    LeverInputSetMouseButton(&state, 0, false);
    frame = LeverInputSample(&state, 0.1);
    assert(frame.buttons[0] == 1 && frame.buttons[2] == 1);
    frame = LeverInputSample(&state, 0.001);
    assert(frame.buttons[0] == 1 && frame.buttons[2] == 1);
    for (int i = 0; i < 6; ++i) frame = LeverInputSample(&state, 1.0 / 120.0);
    assert(frame.buttons[0] == 0 && frame.buttons[2] == 0);
    LeverInputReset(&state);
    state.captured = true;
    LeverInputMotion(&state, NAN, INFINITY);
    frame = LeverInputSample(&state, 0);
    assert(frame.axes[2] == 0 && frame.axes[3] == 0);
    puts("PASS NativeInput — proporción, inversión, límites, diagonal, pulsaciones breves y liberación");
}
