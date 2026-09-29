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

bool FSPassiveDragCandidate(FSRect w,double x,double y) {
    if(!isfinite(x)||!isfinite(y)||!isfinite(w.x)||!isfinite(w.y)||
       !isfinite(w.width)||!isfinite(w.height)||w.width<160||w.height<80)return false;
    double band=fmin(100,fmax(56,w.height*.2));
    return x>=w.x+8 && x<w.x+w.width-8 && y>=w.y+3 && y<w.y+band;
}

bool FSVisibleFrameMatch(FSRect axWindow,FSRect visibleWindow) {
    double a=axWindow.width*axWindow.height,b=visibleWindow.width*visibleWindow.height;
    if(!isfinite(a)||!isfinite(b)||a<=0||b<=0 ||
       fmin(a,b)/fmax(a,b)<.55)return false;
    return FSIntersectionArea(axWindow,visibleWindow)/fmin(a,b)>=.72;
}

bool FSWindowWasDragged(FSRect before, FSRect after) {
    if(!isfinite(before.x)||!isfinite(before.y)||!isfinite(after.x)||!isfinite(after.y)||
       !isfinite(before.width)||!isfinite(before.height)||!isfinite(after.width)||!isfinite(after.height))return false;
    return fabs(after.width-before.width)<=3 && fabs(after.height-before.height)<=3 &&
           hypot(after.x-before.x,after.y-before.y)>=12;
}

bool FSWindowTitleMoved(FSRect before,FSRect after,double downX,double downY) {
    return FSWindowTitleMovedFromVisible(before,after,before,downX,downY);
}

bool FSWindowTitleMovedFromVisible(FSRect before,FSRect after,FSRect visible,
                                   double downX,double downY) {
    return FSTitleCandidate(visible,downX,downY) &&
           isfinite(before.x) && isfinite(before.y) &&
           isfinite(after.x) && isfinite(after.y) &&
           isfinite(after.width) && isfinite(after.height) &&
           after.width>0 && after.height>0 &&
           hypot(after.x-before.x,after.y-before.y)>=12;
}

bool FSPointerDragIntent(FSRect sourceWindow,int source,bool plainChrome,
                         double downX,double downY,double upX,double upY) {
    /* The drop-only band includes current macOS title bars up to 56 points.
       The active mouse blocker remains narrower because it consumes clicks. */
    bool topBand=FSTitleCandidate(sourceWindow,downX,downY) ||
                 (plainChrome && FSPassiveDragCandidate(sourceWindow,downX,downY) &&
                 downX>=sourceWindow.x+80 && downX<sourceWindow.x+sourceWindow.width-20 &&
                 downY<sourceWindow.y+56);
    return source>=0 && topBand &&
           isfinite(upX) && isfinite(upY) && hypot(upX-downX,upY-downY)>=80;
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

int FSDropDestination(const FSRect zones[4],int count,int source,
                      double mouseX,double mouseY,FSRect droppedWindow) {
    int mouse=FSDropZoneAt(zones,count,mouseX,mouseY);
    if(mouse<0 || mouse!=source || source<0)return mouse;
    int center=FSDropZoneAt(zones,count,droppedWindow.x+droppedWindow.width/2,
                                          droppedWindow.y+droppedWindow.height/2);
    return center>=0 && center!=source?center:mouse;
}

FSDropAction FSDropChooseAction(int count,int source,int target,unsigned pinned,bool targetOccupied) {
    if(count<1 || count>4 || source<-1 || source>=count || target<0 || target>=count || source==target)
        return FSDropIgnore;
    if((pinned & (1u<<target)) || (source>=0 && (pinned & (1u<<source))))return FSDropBlocked;
    if(!targetOccupied)return FSDropMove;
    return source>=0?FSDropSwap:FSDropReplace;
}
