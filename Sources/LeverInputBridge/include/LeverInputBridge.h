#ifndef LEVER_INPUT_BRIDGE_H
#define LEVER_INPUT_BRIDGE_H

// El GUID procede de la SDL instalada, también al sondear desde Lever. No se deriva del nombre
// del mando ni de identificadores de fabricante que SDL puede normalizar de otra manera.
int LeverBridgeProbe(const char *sdlPath, char *guid, int capacity);

#endif
