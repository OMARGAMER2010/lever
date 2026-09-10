#include "LeverInputState.h"
#include <math.h>
#include <string.h>

void LeverInputInit(LeverInputState *state) {
    memset(state, 0, sizeof(*state));
    for (int i = 0; i < 15; ++i) state->buttonKeys[i] = -1;
    for (int i = 0; i < 2; ++i) state->triggerKeys[i] = -1;
    for (int i = 0; i < 8; ++i) state->directionKeys[i] = -1;
    state->sensitivity = 1;
}

void LeverInputReset(LeverInputState *state) {
    memset(state->keys, 0, sizeof(state->keys));
    memset(state->mouseButtons, 0, sizeof(state->mouseButtons));
    memset(state->keyPulse, 0, sizeof(state->keyPulse));
    memset(state->mousePulse, 0, sizeof(state->mousePulse));
    state->captured = false;
    state->pendingX = state->pendingY = 0;
    state->velocityX = state->velocityY = state->idleTime = 0;
}

void LeverInputSetKey(LeverInputState *state, unsigned key, bool pressed) {
    if (key >= 128) return;
    // Una pulsación puede terminar entre dos lecturas SDL. Conservar el flanco durante
    // 33 ms lo hace visible al juego a 30–60 Hz sin retrasar el inicio ni prolongar
    // teclas mantenidas. La pérdida de foco cancela también estos pulsos.
    if (pressed && !state->keys[key]) state->keyPulse[key] = -1;
    state->keys[key] = pressed;
}

void LeverInputSetMouseButton(LeverInputState *state, unsigned button, bool pressed) {
    if (button >= 2) return;
    if (pressed && !state->mouseButtons[button]) state->mousePulse[button] = -1;
    state->mouseButtons[button] = pressed;
}

void LeverInputMotion(LeverInputState *state, double x, double y) {
    if (!state->captured || !isfinite(x) || !isfinite(y)) return;
    state->pendingX += x;
    state->pendingY += y;
}

static bool held(const LeverInputState *state, int key) {
    return key >= 0 && key < 128 && state->keys[key];
}

static bool buttonHeld(const LeverInputState *state, int key) {
    return key >= 0 && key < 128 && (state->keys[key] || state->keyPulse[key] != 0);
}

static double advancePulse(double pulse, double dt) {
    // -1 marca un flanco todavía no observado. Su plazo empieza con la primera lectura,
    // para no descontarle el tiempo que transcurrió antes de pulsar la tecla.
    return pulse < 0 ? 1.0 / 30.0 : fmax(0, pulse - dt);
}

static void stick(double x, double y, int16_t *axes) {
    double longitud = hypot(x, y);
    if (longitud > 1) { x /= longitud; y /= longitud; }
    axes[0] = (int16_t)(x * 32767);
    axes[1] = (int16_t)(y * 32767);
}

LeverInputFrame LeverInputSample(LeverInputState *state, double elapsed) {
    LeverInputFrame frame = {0};
    double dt = isfinite(elapsed) && elapsed > 0 ? fmin(elapsed, 0.1) : 1.0 / 60.0;
    for (int i = 0; i < 15; ++i) frame.buttons[i] = buttonHeld(state, state->buttonKeys[i]);
    if (state->captured && (state->mouseButtons[0] || state->mousePulse[0] != 0)) frame.buttons[2] = 1;
    for (int i = 0; i < 2; ++i) {
        bool down = buttonHeld(state, state->triggerKeys[i]);
        if (i == 0 && state->captured && (state->mouseButtons[1] || state->mousePulse[1] != 0)) down = true;
        frame.axes[4 + i] = down ? 32767 : -32768;
    }
    for (int i = 0; i < 2; ++i) {
        const int *direcciones = &state->directionKeys[i * 4];
        stick(held(state, direcciones[3]) - held(state, direcciones[2]),
              held(state, direcciones[1]) - held(state, direcciones[0]), &frame.axes[i * 2]);
    }
    if (state->captured) {
        // SDL consulta a una frecuencia distinta de la del juego. Usar velocidad y tiempo real
        // evita que la sensibilidad cambie al pasar de 60 a 120 FPS o al mover otro mando.
        bool movimiento = state->pendingX != 0 || state->pendingY != 0;
        state->idleTime = movimiento ? 0 : state->idleTime + dt;
        double alpha = 1 - exp(-dt / 0.025);
        state->velocityX += alpha * (state->pendingX / dt - state->velocityX);
        state->velocityY += alpha * (state->pendingY / dt - state->velocityY);
        if (state->idleTime >= 0.080) state->velocityX = state->velocityY = 0;
        double sensibilidad = isfinite(state->sensitivity) ? fmax(0.2, fmin(4, state->sensitivity)) : 1;
        stick(state->velocityX * sensibilidad / 700,
              state->velocityY * sensibilidad / 700 * (state->invertY ? -1 : 1), &frame.axes[2]);
    }
    state->pendingX = state->pendingY = 0;
    for (int i = 0; i < 128; ++i) state->keyPulse[i] = advancePulse(state->keyPulse[i], dt);
    for (int i = 0; i < 2; ++i) state->mousePulse[i] = advancePulse(state->mousePulse[i], dt);
    return frame;
}
