#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <pthread.h>
#include <time.h>
#include "LeverInputBridge.h"
#include "LeverInputState.h"
#include "SDLInterface.h"

static const char *deviceName = "Lever Keyboard and Mouse";
static const uint32_t subsystems = 0x2200;
static LeverSDL sdl;
static void *joystick;
static LeverInputState input;
static pthread_mutex_t inputLock = PTHREAD_MUTEX_INITIALIZER;
static double lastUpdate;
static NSString *sessionPath;
static NSString *statusPath;
static NSString *deviceGUID;
static __weak NSView *capturedView;
static id eventMonitor;
static NSTimer *watchdog;
static BOOL cursorHidden, menuTracking, stopped;
static NSString *lastStatusSignature;
static uint64_t updates, motionEvents;
static int minimumX, maximumX, minimumY, maximumY;

static double monotonicTime(void) {
    struct timespec tiempo;
    clock_gettime(CLOCK_MONOTONIC, &tiempo);
    return tiempo.tv_sec + tiempo.tv_nsec / 1e9;
}

static BOOL loadSDL(const char *path, LeverSDL *api) {
    void *biblioteca = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!biblioteca) return NO;
#define LOAD(field, symbol) api->field = dlsym(biblioteca, symbol); if (!api->field) return NO
    LOAD(InitSubSystem, "SDL_InitSubSystem");
    LOAD(QuitSubSystem, "SDL_QuitSubSystem");
    LOAD(JoystickAttachVirtualEx, "SDL_JoystickAttachVirtualEx");
    LOAD(JoystickDetachVirtual, "SDL_JoystickDetachVirtual");
    LOAD(JoystickOpen, "SDL_JoystickOpen");
    LOAD(JoystickClose, "SDL_JoystickClose");
    LOAD(JoystickSetVirtualAxis, "SDL_JoystickSetVirtualAxis");
    LOAD(JoystickSetVirtualButton, "SDL_JoystickSetVirtualButton");
    LOAD(IsGameController, "SDL_IsGameController");
    LOAD(GameControllerMappingForDeviceIndex, "SDL_GameControllerMappingForDeviceIndex");
    LOAD(Free, "SDL_free");
    LOAD(JoystickInstanceID, "SDL_JoystickInstanceID");
    LOAD(GameControllerFromInstanceID, "SDL_GameControllerFromInstanceID");
    LOAD(GameControllerGetAxis, "SDL_GameControllerGetAxis");
#undef LOAD
    return YES;
}

static LeverSDLDescriptor descriptor(void (*update)(void *)) {
    LeverSDLDescriptor descripción = {0};
    descripción.version = 1;
    descripción.type = 1;
    descripción.naxes = 6;
    descripción.nbuttons = 15;
    descripción.button_mask = 0x7fff;
    descripción.axis_mask = 0x3f;
    descripción.name = deviceName;
    descripción.Update = update;
    return descripción;
}

static BOOL copyGUID(LeverSDL *api, int index, char *guid, int capacity) {
    if (capacity < 33 || !api->IsGameController(index)) return NO;
    char *mapa = api->GameControllerMappingForDeviceIndex(index);
    if (!mapa) return NO;
    BOOL válido = strlen(mapa) > 32 && mapa[32] == ',';
    if (válido) { memcpy(guid, mapa, 32); guid[32] = 0; }
    api->Free(mapa);
    return válido;
}

int LeverBridgeProbe(const char *sdlPath, char *guid, int capacity) {
    LeverSDL api = {0};
    if (!loadSDL(sdlPath, &api) || api.InitSubSystem(subsystems) != 0) return -1;
    LeverSDLDescriptor descripción = descriptor(NULL);
    int índice = api.JoystickAttachVirtualEx(&descripción);
    int resultado = índice >= 0 && copyGUID(&api, índice, guid, capacity) ? 0 : -2;
    if (índice >= 0) api.JoystickDetachVirtual(índice);
    api.QuitSubSystem(subsystems);
    return resultado;
}

static void updateJoystick(void *unused) {
    if (!joystick) return;
    double ahora = monotonicTime();
    pthread_mutex_lock(&inputLock);
    LeverInputFrame frame = LeverInputSample(&input, lastUpdate ? ahora - lastUpdate : 1.0 / 60);
    lastUpdate = ahora;
    updates++;
    minimumX = MIN(minimumX, frame.axes[2]); maximumX = MAX(maximumX, frame.axes[2]);
    minimumY = MIN(minimumY, frame.axes[3]); maximumY = MAX(maximumY, frame.axes[3]);
    pthread_mutex_unlock(&inputLock);
    for (int i = 0; i < 6; ++i) sdl.JoystickSetVirtualAxis(joystick, i, frame.axes[i]);
    for (int i = 0; i < 15; ++i) sdl.JoystickSetVirtualButton(joystick, i, frame.buttons[i]);
}

static void writeStatus(NSString *state, NSString *reason) {
    if (!statusPath) return;
    if (stopped) state = @"stopped";
    bool opened = joystick && sdl.GameControllerFromInstanceID(sdl.JoystickInstanceID(joystick)) != NULL;
    pthread_mutex_lock(&inputLock);
    NSString *firma = [NSString stringWithFormat:@"%@/%@/%d/%d", state, reason ?: @"", input.captured, opened];
    if ([firma isEqualToString:lastStatusSignature] && !getenv("LEVER_INPUT_DIAGNOSTICS")) {
        pthread_mutex_unlock(&inputLock); return;
    }
    lastStatusSignature = firma;
    NSDictionary *estado = @{
        @"version": @1, @"state": state, @"reason": reason ?: @"", @"guid": deviceGUID ?: @"",
        @"captured": @(input.captured), @"updates": @(updates), @"motionEvents": @(motionEvents),
        @"minX": @(minimumX), @"maxX": @(maximumX), @"minY": @(minimumY), @"maxY": @(maximumY)
    };
    pthread_mutex_unlock(&inputLock);
    NSMutableDictionary *salida = [estado mutableCopy];
    salida[@"controllerOpened"] = @(opened);
    if (getenv("LEVER_INPUT_DIAGNOSTICS")) {
        NSMutableArray *ventanas = [NSMutableArray array];
        for (NSWindow *ventana in NSApp.windows) if (ventana.visible) {
            [ventanas addObject:@{@"class": NSStringFromClass(ventana.class), @"level": @(ventana.level),
                @"key": @((bool)ventana.keyWindow), @"content": NSStringFromClass(ventana.contentView.class) ?: @""}];
        }
        salida[@"windows"] = ventanas;
    }
    NSData *datos = [NSJSONSerialization dataWithJSONObject:salida options:NSJSONWritingSortedKeys error:nil];
    [datos writeToFile:statusPath options:NSDataWritingAtomic error:nil];
}

static void releaseCapture(void) {
    pthread_mutex_lock(&inputLock);
    LeverInputReset(&input);
    pthread_mutex_unlock(&inputLock);
    capturedView = nil;
    if (cursorHidden) {
        CGAssociateMouseAndMouseCursorPosition(true);
        [NSCursor unhide];
        cursorHidden = NO;
    }
}

static NSView *findRenderView(NSView *view) {
    if (view.hidden || view.bounds.size.width < 160 || view.bounds.size.height < 100) return nil;
    // Ryujinx 1.3.3 crea un NSView simple con CAMetalLayer. Avalonia dibuja sus controles en
    // otra clase: aceptar cualquier capa Metal también capturaría ajustes y selectores.
    if ([NSStringFromClass(view.class) isEqualToString:@"NSView"] && [view.layer isKindOfClass:CAMetalLayer.class]) return view;
    for (NSView *hijo in view.subviews) {
        NSView *resultado = findRenderView(hijo);
        if (resultado) return resultado;
    }
    return nil;
}

static NSView *activeRenderView(void) {
    NSWindow *ventana = NSApp.keyWindow;
    if (!NSApp.active || menuTracking || !ventana || ventana.attachedSheet || NSApp.modalWindow) return nil;
    if ([ventana isKindOfClass:NSPanel.class]) return nil;
    for (NSWindow *otra in NSApp.windows) {
        if (otra == ventana || !otra.visible || otra.alphaValue == 0) continue;
        // Avalonia dibuja sus menús en ventanas propias, por lo que NSMenuDidBeginTracking no
        // basta. Un popup visible sobre la partida tiene prioridad sobre la captura.
        if (otra.parentWindow == ventana || (otra.level > ventana.level &&
            [NSStringFromClass(otra.class) hasPrefix:@"Avn"])) return nil;
    }
    return findRenderView(ventana.contentView);
}

static BOOL configuredKey(unsigned code) {
    for (int i = 0; i < 15; ++i) if (input.buttonKeys[i] == code) return YES;
    for (int i = 0; i < 8; ++i) if (input.directionKeys[i] == code) return YES;
    for (int i = 0; i < 2; ++i) if (input.triggerKeys[i] == code) return YES;
    return NO;
}

static NSEvent *handleEvent(NSEvent *event) {
    NSView *render = activeRenderView();
    if (!render || (capturedView && capturedView != render)) releaseCapture();
    if (!render || stopped) return event;
    if (event.window && event.window != render.window) { releaseCapture(); return event; }
    if (event.modifierFlags & NSEventModifierFlagCommand) { releaseCapture(); return event; }
    if ((event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) && event.keyCode == 53) {
        // Ryujinx usa Escape para terminar la partida. Se reserva el ciclo completo mientras
        // el render tiene el foco, incluso tras soltar el ratón o repetir la tecla.
        // Los diálogos siguen recibiendo Escape porque no pasan la comprobación de render.
        if (event.type == NSEventTypeKeyDown) { releaseCapture(); writeStatus(@"ready", @"escape"); }
        return nil;
    }
    if (event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeRightMouseDown) {
        NSPoint punto = [render convertPoint:event.locationInWindow fromView:nil];
        if (!NSPointInRect(punto, render.bounds) || event.window != render.window) {
            releaseCapture(); return event;
        }
        if (!cursorHidden) {
            // El clic que captura no dispara una acción del juego, igual que al volver desde
            // otra aplicación. Los siguientes clics ya son los botones del mando.
            if (CGAssociateMouseAndMouseCursorPosition(false) != kCGErrorSuccess) return event;
            [NSCursor hide]; cursorHidden = YES; capturedView = render;
            pthread_mutex_lock(&inputLock); input.captured = true; pthread_mutex_unlock(&inputLock);
            writeStatus(@"ready", @"captured"); return nil;
        }
    }
    if (cursorHidden && (event.type == NSEventTypeMouseMoved || event.type == NSEventTypeLeftMouseDragged || event.type == NSEventTypeRightMouseDragged)) {
        pthread_mutex_lock(&inputLock);
        LeverInputMotion(&input, event.deltaX, event.deltaY); motionEvents++;
        pthread_mutex_unlock(&inputLock);
        return nil;
    }
    if (cursorHidden && (event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeLeftMouseUp || event.type == NSEventTypeRightMouseDown || event.type == NSEventTypeRightMouseUp)) {
        int botón = event.type == NSEventTypeRightMouseDown || event.type == NSEventTypeRightMouseUp ? 1 : 0;
        BOOL pulsado = event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeRightMouseDown;
        pthread_mutex_lock(&inputLock); LeverInputSetMouseButton(&input, botón, pulsado); pthread_mutex_unlock(&inputLock);
        return nil;
    }
    if ((event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp || event.type == NSEventTypeFlagsChanged) && configuredKey(event.keyCode)) {
        BOOL pulsado = event.type == NSEventTypeKeyDown;
        if (event.type == NSEventTypeFlagsChanged) {
            // Los bits dependientes del dispositivo distinguen Shift izquierdo y derecho.
            uint64_t mask = event.keyCode == 56 ? 0x2 : event.keyCode == 60 ? 0x4 :
                event.keyCode == 59 ? 0x1 : event.keyCode == 62 ? 0x2000 :
                event.keyCode == 58 ? 0x20 : event.keyCode == 61 ? 0x40 : 0;
            pulsado = event.keyCode == 57 ? (event.modifierFlags & NSEventModifierFlagCapsLock) != 0 : mask && (event.modifierFlags & mask);
        }
        pthread_mutex_lock(&inputLock); LeverInputSetKey(&input, event.keyCode, pulsado); pthread_mutex_unlock(&inputLock);
        return nil;
    }
    return event;
}

static void installEvents(void) {
    NSEventMask tipos = NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged |
        NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDragged |
        NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskRightMouseDown | NSEventMaskRightMouseUp;
    eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:tipos handler:^NSEvent *(NSEvent *evento) { return handleEvent(evento); }];
    NSNotificationCenter *centro = NSNotificationCenter.defaultCenter;
    for (NSNotificationName nombre in @[NSApplicationDidResignActiveNotification, NSWindowDidResignKeyNotification, NSWindowWillCloseNotification]) {
        [centro addObserverForName:nombre object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *nota) {
            releaseCapture(); writeStatus(@"ready", @"focus");
        }];
    }
    [centro addObserverForName:NSMenuDidBeginTrackingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *nota) { menuTracking = YES; releaseCapture(); }];
    [centro addObserverForName:NSMenuDidEndTrackingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *nota) { menuTracking = NO; }];
    [centro addObserverForName:NSApplicationWillTerminateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *nota) { releaseCapture(); stopped = YES; }];
    __block unsigned ticks = 0;
    watchdog = [NSTimer timerWithTimeInterval:0.02 repeats:YES block:^(NSTimer *timer) {
        NSView *render = activeRenderView();
        if (!render || (capturedView && render != capturedView)) releaseCapture();
        if (render) render.window.acceptsMouseMovedEvents = YES;
        if (![[NSFileManager defaultManager] fileExistsAtPath:sessionPath]) {
            releaseCapture(); stopped = YES; [NSEvent removeMonitor:eventMonitor]; [timer invalidate];
            return;
        }
        if (++ticks % 50 == 0) writeStatus(@"ready", render ? @"render-visible" : @"waiting-render");
    }];
    [NSRunLoop.mainRunLoop addTimer:watchdog forMode:NSRunLoopCommonModes];
    writeStatus(@"ready", @"monitor-installed");
}

__attribute__((constructor)) static void beginSession(void) {
    const char *ruta = getenv("LEVER_INPUT_SESSION");
    if (!ruta) return;
    @autoreleasepool {
        sessionPath = [NSString stringWithUTF8String:ruta];
        statusPath = [[sessionPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"status.json"];
        NSData *datos = [NSData dataWithContentsOfFile:sessionPath];
        NSDictionary *config = datos ? [NSJSONSerialization JSONObjectWithData:datos options:0 error:nil] : nil;
        if (![config isKindOfClass:NSDictionary.class] || ![config[@"version"] isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)config[@"version"]) == CFBooleanGetTypeID() ||
            [config[@"version"] intValue] != 1 || ![config[@"sdlPath"] isKindOfClass:NSString.class]) {
            writeStatus(@"failed", @"invalid-session"); return;
        }
        LeverInputInit(&input);
        NSArray *buttons = config[@"buttonKeys"], *triggers = config[@"triggerKeys"], *directions = config[@"directionKeys"];
        if (![buttons isKindOfClass:NSArray.class] || buttons.count != 15 || ![triggers isKindOfClass:NSArray.class] || triggers.count != 2 || ![directions isKindOfClass:NSArray.class] || directions.count != 8) {
            writeStatus(@"failed", @"invalid-bindings"); return;
        }
        for (NSArray *grupo in @[buttons, triggers, directions]) for (id valor in grupo) {
            if (![valor isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)valor) == CFBooleanGetTypeID() ||
                [valor doubleValue] != [valor intValue] || [valor intValue] < -1 || [valor intValue] >= 128 ||
                [valor intValue] == 53 || [valor intValue] == 54 || [valor intValue] == 55) { writeStatus(@"failed", @"invalid-key"); return; }
        }
        for (int i = 0; i < 15; ++i) input.buttonKeys[i] = [buttons[i] intValue];
        for (int i = 0; i < 2; ++i) input.triggerKeys[i] = [triggers[i] intValue];
        for (int i = 0; i < 8; ++i) input.directionKeys[i] = [directions[i] intValue];
        if (![config[@"sensitivity"] isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)config[@"sensitivity"]) == CFBooleanGetTypeID() ||
            [config[@"sensitivity"] doubleValue] < 0.2 || [config[@"sensitivity"] doubleValue] > 4 ||
            ![config[@"invertY"] isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)config[@"invertY"]) != CFBooleanGetTypeID()) {
            writeStatus(@"failed", @"invalid-settings"); return;
        }
        input.sensitivity = [config[@"sensitivity"] doubleValue];
        input.invertY = [config[@"invertY"] boolValue];
        if (!loadSDL([config[@"sdlPath"] fileSystemRepresentation], &sdl) || sdl.InitSubSystem(subsystems) != 0) { writeStatus(@"failed", @"sdl-unavailable"); return; }
        LeverSDLDescriptor descripción = descriptor(updateJoystick);
        int índice = sdl.JoystickAttachVirtualEx(&descripción);
        char guid[33];
        if (índice < 0 || !copyGUID(&sdl, índice, guid, sizeof(guid)) || !(joystick = sdl.JoystickOpen(índice))) { writeStatus(@"failed", @"virtual-controller-failed"); return; }
        deviceGUID = [NSString stringWithUTF8String:guid];
        updateJoystick(NULL);
        writeStatus(@"ready", @"attached");
        dispatch_async(dispatch_get_main_queue(), ^{ installEvents(); });
    }
}
