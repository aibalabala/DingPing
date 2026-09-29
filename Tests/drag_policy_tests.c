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
    FSRect moved={-800,-400,1200,850},resized={-800,-400,800,850};
    assert(FSWindowWasDragged(w,moved));
    assert(!FSWindowWasDragged(w,resized));
    assert(!FSWindowWasDragged(w,(FSRect){-1435,-1080,1200,850}));
    assert(!FSWindowWasDragged(w,(FSRect){NAN,0,1200,850}));
    FSRect zones[4]={{-1440,-1080,600,850},{-830,-1080,600,850},{0,0,1,1},{0,0,1,1}};
    assert(FSDropZoneAt(zones,2,-900,-700)==0);
    assert(FSDropZoneAt(zones,2,-800,-700)==1);
    assert(FSDropZoneAt(zones,2,-835,-700)==-1); /* gap */
    assert(FSDropZoneAt(zones,2,NAN,-700)==-1);
    assert(FSDropChooseAction(2,0,1,0,true)==FSDropSwap);
    assert(FSDropChooseAction(2,0,1,0,false)==FSDropMove);
    assert(FSDropChooseAction(2,-1,1,0,true)==FSDropReplace);
    assert(FSDropChooseAction(2,0,1,1u<<0,true)==FSDropBlocked);
    assert(FSDropChooseAction(2,0,1,1u<<1,true)==FSDropBlocked);
    assert(FSDropChooseAction(2,0,0,0,true)==FSDropIgnore);
    assert(FSDropChooseAction(2,0,-1,0,false)==FSDropIgnore);
    puts("PASS: drag sequence pairing, content pass-through, title-bar translation, zone drop, pin-safe swap.");
    return 0;
}
