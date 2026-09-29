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
