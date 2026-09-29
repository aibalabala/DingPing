#ifndef FS_PLACEMENT_POLICY_H
#define FS_PLACEMENT_POLICY_H
#include <stdbool.h>
#include <stdint.h>

/* No platform dependencies: these are the rules used by the real controller. */
typedef struct {
    bool enabled;
    bool switching;
    uint64_t generation;
    int lastSlot;
} FSPlacementState;

void FSPlacementSetEnabled(FSPlacementState *state, bool enabled);
void FSPlacementCancelSwitch(FSPlacementState *state);
uint64_t FSPlacementBeginSwitch(FSPlacementState *state);
bool FSPlacementSwitchIsCurrent(const FSPlacementState *state, uint64_t token);
bool FSPlacementFinishSwitch(FSPlacementState *state, uint64_t token);
int FSPlacementChooseSlot(const FSPlacementState *state, int count, int knownSlot, unsigned occupied);
#endif
