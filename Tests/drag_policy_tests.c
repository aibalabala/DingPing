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
    puts("PASS: drag sequence pairing, content pass-through, reset, title-band boundaries.");
    return 0;
}
