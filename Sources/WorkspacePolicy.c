#include "WorkspacePolicy.h"

void FSWorkspaceEnable(FSWorkspaceGate *g,bool enabled) {
    ++g->generation;g->enabled=enabled;
    g->switching=false;g->dragging=false;g->dropPending=false;
}
bool FSWorkspaceIdle(const FSWorkspaceGate *g) {
    return g && g->enabled && !g->switching && !g->dragging && !g->dropPending;
}
uint64_t FSWorkspaceBeginDrag(FSWorkspaceGate *g) {
    if(!FSWorkspaceIdle(g))return 0;
    ++g->generation;g->dragging=true;return g->generation;
}
bool FSWorkspaceReleaseDrag(FSWorkspaceGate *g,uint64_t token) {
    if(!g->enabled || !g->dragging || g->generation!=token)return false;
    g->dragging=false;g->dropPending=true;return true;
}
bool FSWorkspaceFinishDrag(FSWorkspaceGate *g,uint64_t token) {
    if(!g->enabled || g->generation!=token || (!g->dragging && !g->dropPending))return false;
    g->dragging=false;g->dropPending=false;return true;
}
uint64_t FSWorkspaceBeginSwitch(FSWorkspaceGate *g) {
    if(!g || g->dragging || g->dropPending)return 0;
    ++g->generation;g->enabled=true;g->switching=true;return g->generation;
}
bool FSWorkspaceFinishSwitch(FSWorkspaceGate *g,uint64_t token) {
    if(!g->enabled || !g->switching || g->generation!=token)return false;
    g->switching=false;return true;
}
bool FSWorkspaceCommandCurrent(const FSWorkspaceGate *g,uint64_t token) {
    return g && g->enabled && g->generation==token && !g->dragging && !g->dropPending;
}
int FSWorkspaceChooseSlot(int count,int known,int active,const unsigned population[4],bool preferActive) {
    if(count<1 || count>4 || !population)return -1;
    if(known>=0 && known<count)return known;
    if(preferActive && active>=0 && active<count)return active;
    int best=0;
    for(int i=1;i<count;i++)if(population[i]<population[best])best=i;
    return best;
}
