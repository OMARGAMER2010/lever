#ifndef LEVER_INPUT_STATE_H
#define LEVER_INPUT_STATE_H
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    int16_t axes[6];
    uint8_t buttons[15];
} LeverInputFrame;

typedef struct {
    bool keys[128];
    double keyPulse[128], mousePulse[2];
    int buttonKeys[15], triggerKeys[2], directionKeys[8];
    bool mouseButtons[2];
    bool captured, invertY;
    double sensitivity, pendingX, pendingY, velocityX, velocityY, idleTime;
} LeverInputState;

void LeverInputInit(LeverInputState *state);
void LeverInputReset(LeverInputState *state);
void LeverInputSetKey(LeverInputState *state, unsigned key, bool pressed);
void LeverInputSetMouseButton(LeverInputState *state, unsigned button, bool pressed);
void LeverInputMotion(LeverInputState *state, double x, double y);
LeverInputFrame LeverInputSample(LeverInputState *state, double elapsed);
#endif
