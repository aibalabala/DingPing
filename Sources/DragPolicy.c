#include "DragPolicy.h"
#include <math.h>

bool FSFilterDrag(FSDragState *state, FSDragEvent event, bool enabled, bool confirmedTitle) {
    if(!state)return false;
    switch(event) {
        case FSDragDown:
            state->consuming=enabled && confirmedTitle;
            return state->consuming;
        case FSDragMotion:
            return state->consuming;
        case FSDragUp: {
            bool consumed=state->consuming;
            state->consuming=false;
            return consumed;
        }
        case FSDragReset:
            state->consuming=false;
            return false;
    }
    return false;
}

bool FSTitleCandidate(FSRect w,double x,double y) {
    if(!isfinite(x)||!isfinite(y)||!isfinite(w.x)||!isfinite(w.y)||
       !isfinite(w.width)||!isfinite(w.height)||w.width<160||w.height<80)return false;
    /* Exclude traffic lights, borders and content below the top title band.
       This rectangle alone never authorizes suppression: AX hit identity is required. */
    return x>=w.x+80 && x<w.x+w.width-20 && y>=w.y+3 && y<w.y+38;
}

bool FSWindowWasDragged(FSRect before, FSRect after) {
    if(!isfinite(before.x)||!isfinite(before.y)||!isfinite(after.x)||!isfinite(after.y)||
       !isfinite(before.width)||!isfinite(before.height)||!isfinite(after.width)||!isfinite(after.height))return false;
    return fabs(after.width-before.width)<=3 && fabs(after.height-before.height)<=3 &&
           hypot(after.x-before.x,after.y-before.y)>=12;
}

int FSDropZoneAt(const FSRect zones[4],int count,double x,double y) {
    if(!zones || count<1 || count>4 || !isfinite(x) || !isfinite(y))return -1;
    for(int i=0;i<count;i++) {
        FSRect z=zones[i];
        if(isfinite(z.x)&&isfinite(z.y)&&isfinite(z.width)&&isfinite(z.height)&&
           z.width>0&&z.height>0&&x>=z.x&&x<z.x+z.width&&y>=z.y&&y<z.y+z.height)return i;
    }
    return -1;
}

FSDropAction FSDropChooseAction(int count,int source,int target,unsigned pinned,bool targetOccupied) {
    if(count<1 || count>4 || source<-1 || source>=count || target<0 || target>=count || source==target)
        return FSDropIgnore;
    if((pinned & (1u<<target)) || (source>=0 && (pinned & (1u<<source))))return FSDropBlocked;
    if(!targetOccupied)return FSDropMove;
    return source>=0?FSDropSwap:FSDropReplace;
}
