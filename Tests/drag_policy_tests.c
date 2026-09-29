#include "../Sources/DragPolicy.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

int main(void) {
    FSDragState s={false};
    /* Content selection must not be interrupted when crossing a title bar. */
    assert(!FSFilterDrag(&s,FSDragDown,true,false));
    assert(!FSFilterDrag(&s,FSDragMotion,true,true));
    assert(!FSFilterDrag(&s,FSDragUp,true,true));
    /* A protected click consumes a matched sequence, including release. */
    assert(FSFilterDrag(&s,FSDragDown,true,true));
    assert(FSFilterDrag(&s,FSDragMotion,true,false));
    assert(FSFilterDrag(&s,FSDragUp,true,false));
    assert(!s.consuming);
    /* Pausing midway still pairs a suppressed DOWN with its UP. */
    assert(FSFilterDrag(&s,FSDragDown,true,true));
    assert(FSFilterDrag(&s,FSDragMotion,false,false));
    assert(FSFilterDrag(&s,FSDragUp,false,false));
    assert(!FSFilterDrag(&s,FSDragDown,false,true));
    /* Missing release, tap timeout, and unrelated new press recover. */
    assert(FSFilterDrag(&s,FSDragDown,true,true));
    assert(!FSFilterDrag(&s,FSDragDown,true,false));
    assert(!FSFilterDrag(&s,FSDragMotion,true,false));
    assert(FSFilterDrag(&s,FSDragDown,true,true));
    assert(!FSFilterDrag(&s,FSDragReset,true,true));
    assert(!FSFilterDrag(&s,FSDragUp,true,true));
    FSRect w={-1440,-1080,1200,850};
    assert(FSTitleCandidate(w,-1300,-1060));
    assert(!FSTitleCandidate(w,-1420,-1060)); /* traffic lights */
    assert(!FSTitleCandidate(w,-250,-1060)); /* right border */
    assert(!FSTitleCandidate(w,-1300,-1030)); /* content */
    assert(!FSTitleCandidate(w,-1300,-1081)); /* menu bar */
    assert(!FSTitleCandidate(w,NAN,-1060));
    assert(FSPassiveDragCandidate(w,-1300,-1030)); /* A real toolbar is deeper than 38 points. */
    assert(FSPassiveDragCandidate(w,-1300,-1000));
    assert(!FSPassiveDragCandidate(w,-1300,-900)); /* Ordinary content is not a drag origin. */
    assert(!FSPassiveDragCandidate(w,-1435,-1050)); /* The window border cannot start it. */
    assert(FSVisibleFrameMatch(w,(FSRect){-1438,-1077,1196,844}));
    assert(FSVisibleFrameMatch(w,(FSRect){-1440,-1052,1200,820})); /* Different chrome height. */
    assert(!FSVisibleFrameMatch(w,(FSRect){-720,-1080,1200,850})); /* Neighboring window. */
    assert(!FSVisibleFrameMatch(w,(FSRect){-1440,-1080,3000,2000}));
    assert(!FSVisibleFrameMatch(w,(FSRect){NAN,-1080,1200,850}));
    FSRect moved={-800,-400,1200,850},resized={-800,-400,800,850};
    assert(FSWindowWasDragged(w,moved));
    assert(!FSWindowWasDragged(w,resized));
    assert(FSWindowTitleMoved(w,resized,-1300,-1060));
    assert(FSWindowTitleMovedFromVisible(w,resized,(FSRect){-1438,-1077,1196,844},-1300,-1060));
    assert(!FSWindowTitleMoved(w,resized,-1420,-1060)); /* Edge resize, not title drag. */
    assert(!FSWindowWasDragged(w,(FSRect){-1435,-1080,1200,850}));
    assert(!FSWindowWasDragged(w,(FSRect){NAN,0,1200,850}));
    /* A clear title-bar drop still expresses intent if the AX frame springs
       back before the delayed release callback sees it. */
    assert(FSPointerDragIntent(w,0,false,-1300,-1060,-800,-700));
    assert(FSPointerDragIntent(w,0,true,-1300,-1030,-800,-700)); /* Confirmed taller chrome. */
    assert(!FSPointerDragIntent(w,0,false,-1300,-1030,-800,-700));
    assert(!FSPointerDragIntent(w,-1,true,-1300,-1060,-800,-700));
    assert(!FSPointerDragIntent(w,0,true,-1300,-900,-800,-700));
    assert(!FSPointerDragIntent(w,0,true,-1300,-1000,-800,-700)); /* Content/toolbar. */
    assert(!FSPointerDragIntent(w,0,true,-1300,-1060,-1260,-1060));
    assert(!FSPointerDragIntent(w,0,true,-1300,-1060,NAN,-700));
    FSRect zones[4]={{-1440,-1080,600,850},{-830,-1080,600,850},{0,0,1,1},{0,0,1,1}};
    assert(FSDropZoneAt(zones,2,-900,-700)==0);
    assert(FSDropZoneAt(zones,2,-800,-700)==1);
    assert(FSDropZoneAt(zones,2,-835,-700)==-1); /* gap */
    assert(FSDropZoneAt(zones,2,NAN,-700)==-1);
    assert(FSDropDestination(zones,2,0,-900,-700,(FSRect){-825,-1080,600,850})==1);
    assert(FSDropDestination(zones,2,0,-800,-700,w)==1);
    assert(FSDropDestination(zones,2,0,-835,-700,(FSRect){-825,-1080,600,850})==-1);
    assert(FSDropChooseAction(2,0,1,0,true)==FSDropSwap);
    assert(FSDropChooseAction(2,0,1,0,false)==FSDropMove);
    assert(FSDropChooseAction(2,-1,1,0,true)==FSDropReplace);
    assert(FSDropChooseAction(2,0,1,1u<<0,true)==FSDropBlocked);
    assert(FSDropChooseAction(2,0,1,1u<<1,true)==FSDropBlocked);
    assert(FSDropChooseAction(2,0,0,0,true)==FSDropIgnore);
    assert(FSDropChooseAction(2,0,-1,0,false)==FSDropIgnore);
    puts("PASS: drag pairing, window movement, springback title intent, drop targets, pin-safe swap.");
    return 0;
}
