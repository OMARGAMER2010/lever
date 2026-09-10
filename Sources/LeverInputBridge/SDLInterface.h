#include <stdint.h>

// Subconjunto del ABI público de SDL 2.30: no se distribuye otra SDL que pueda diferir de la del
// emulador. Descriptor documentado en https://wiki.libsdl.org/SDL2/SDL_VirtualJoystickDesc.
typedef struct {
    uint16_t version, type, naxes, nbuttons, nhats, vendor_id, product_id, padding;
    uint32_t button_mask, axis_mask;
    const char *name;
    void *userdata;
    void (*Update)(void *);
    void (*SetPlayerIndex)(void *, int);
    int (*Rumble)(void *, uint16_t, uint16_t);
    int (*RumbleTriggers)(void *, uint16_t, uint16_t);
    int (*SetLED)(void *, uint8_t, uint8_t, uint8_t);
    int (*SendEffect)(void *, const void *, int);
} LeverSDLDescriptor;

typedef struct {
    int (*InitSubSystem)(uint32_t);
    void (*QuitSubSystem)(uint32_t);
    int (*JoystickAttachVirtualEx)(const LeverSDLDescriptor *);
    int (*JoystickDetachVirtual)(int);
    void *(*JoystickOpen)(int);
    void (*JoystickClose)(void *);
    int (*JoystickSetVirtualAxis)(void *, int, int16_t);
    int (*JoystickSetVirtualButton)(void *, int, uint8_t);
    int (*IsGameController)(int);
    char *(*GameControllerMappingForDeviceIndex)(int);
    void (*Free)(void *);
    int32_t (*JoystickInstanceID)(void *);
    void *(*GameControllerFromInstanceID)(int32_t);
    int16_t (*GameControllerGetAxis)(void *, int);
} LeverSDL;
