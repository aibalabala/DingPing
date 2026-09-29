#include "PlacementPolicy.h"

void FSPlacementCancelSwitch(FSPlacementState *state) {
    ++state->generation;
    state->switching=false;
}
void FSPlacementSetEnabled(FSPlacementState *state, bool enabled) {
    FSPlacementCancelSwitch(state);
    state->enabled=enabled;
}
uint64_t FSPlacementBeginSwitch(FSPlacementState *state) {
    FSPlacementSetEnabled(state,true);
    state->switching=true;
    return state->generation;
}
bool FSPlacementSwitchIsCurrent(const FSPlacementState *state, uint64_t token) {
    return state->enabled && state->switching && state->generation==token;
}
bool FSPlacementFinishSwitch(FSPlacementState *state, uint64_t token) {
    if(!FSPlacementSwitchIsCurrent(state,token))return false;
    state->switching=false;
    return true;
}
int FSPlacementChooseSlot(const FSPlacementState *state, int count, int knownSlot, unsigned occupied) {
    if(!state->enabled || state->switching || count<1 || count>4)return -1;
    if(knownSlot>=0 && knownSlot<count)return knownSlot;
    for(int slot=0;slot<count;++slot)if(!(occupied & (1u<<slot)))return slot;
    return state->lastSlot>=0 && state->lastSlot<count?state->lastSlot:0;
}
