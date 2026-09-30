#ifndef FS_WORKSPACE_POLICY_H
#define FS_WORKSPACE_POLICY_H
#include <stdbool.h>
#include <stdint.h>

/* One gate is shared by input, layout commands and delayed move verification.
   Focus events have no authority to change an existing assignment. */
typedef struct {
    uint64_t generation;
    bool enabled, switching, dragging, dropPending;
} FSWorkspaceGate;
void FSWorkspaceEnable(FSWorkspaceGate *gate, bool enabled);
uint64_t FSWorkspaceBeginDrag(FSWorkspaceGate *gate);
bool FSWorkspaceReleaseDrag(FSWorkspaceGate *gate, uint64_t token);
bool FSWorkspaceFinishDrag(FSWorkspaceGate *gate, uint64_t token);
uint64_t FSWorkspaceBeginSwitch(FSWorkspaceGate *gate);
bool FSWorkspaceFinishSwitch(FSWorkspaceGate *gate, uint64_t token);
bool FSWorkspaceIdle(const FSWorkspaceGate *gate);
bool FSWorkspaceCommandCurrent(const FSWorkspaceGate *gate, uint64_t token);
/* Existing membership always wins. New windows prefer the selected zone if
   requested; otherwise fill empty zones, then the least populated zone. */
int FSWorkspaceChooseSlot(int count, int known, int active,
                          const unsigned population[4], bool preferActive);
#endif
