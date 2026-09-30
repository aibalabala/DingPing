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
/* reserved marks slots where the fixed owner is currently present. A missing
   fixed target can be borrowed; the binding planner restores its owner first. */
int FSPlacementChooseAvailableSlot(const FSPlacementState *state, int count, int knownSlot,
                                    unsigned occupied, unsigned reserved);
/* Only for a confirmed newly created window. An unpinned active slot wins
   even if other slots are empty; other windows keep the ordinary policy. */
int FSPlacementChooseNewWindowSlot(const FSPlacementState *state, int count, int activeSlot,
                                   unsigned occupied, unsigned reserved, bool preferActive);
#endif
