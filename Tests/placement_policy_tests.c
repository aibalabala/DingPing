#include "../Sources/PlacementPolicy.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    FSPlacementState state={0};
    assert(FSPlacementChooseSlot(&state,2,-1,0)==-1); /* First launch is free. */
    FSPlacementSetEnabled(&state,true);
    assert(FSPlacementChooseSlot(&state,2,-1,0)==0);
    assert(FSPlacementChooseSlot(&state,2,-1,1)==1);
    state.lastSlot=1;
    assert(FSPlacementChooseSlot(&state,2,-1,3)==1); /* New chat replaces right. */
    assert(FSPlacementChooseSlot(&state,2,0,3)==0); /* Browser returns left. */
    assert(FSPlacementChooseSlot(&state,2,1,1)==1); /* Minimized doc keeps its slot. */
    state.lastSlot=3;
    assert(FSPlacementChooseSlot(&state,2,3,3)==0); /* Four -> two, no out of bounds. */
    assert(FSPlacementChooseSlot(&state,0,-1,0)==-1);
    assert(FSPlacementChooseSlot(&state,5,-1,0)==-1);
    uint64_t first=FSPlacementBeginSwitch(&state);
    assert(FSPlacementChooseSlot(&state,2,-1,0)==-1); /* Internal focus is suppressed. */
    uint64_t last=FSPlacementBeginSwitch(&state);
    assert(!FSPlacementFinishSwitch(&state,first)); /* Last click wins. */
    assert(FSPlacementSwitchIsCurrent(&state,last));
    assert(FSPlacementFinishSwitch(&state,last));
    assert(!FSPlacementFinishSwitch(&state,last));
    first=FSPlacementBeginSwitch(&state);
    FSPlacementSetEnabled(&state,false);
    assert(!FSPlacementFinishSwitch(&state,first)); /* Free mode cancels queued work. */
    assert(FSPlacementChooseSlot(&state,2,1,3)==-1);
    first=FSPlacementBeginSwitch(&state);
    FSPlacementCancelSwitch(&state); /* New user input cancels foreground handoff. */
    assert(!FSPlacementSwitchIsCurrent(&state,first));
    for(int count=1;count<=4;++count)for(unsigned mask=0;mask<16;++mask)
        for(int lastSlot=-1;lastSlot<5;++lastSlot)for(int known=-1;known<5;++known) {
            state.lastSlot=lastSlot;
            int result=FSPlacementChooseSlot(&state,count,known,mask);
            assert(result>=0 && result<count);
            if(known>=0 && known<count)assert(result==known);
            else if(mask!=((1u<<count)-1) && (mask&((1u<<count)-1))!=((1u<<count)-1)) {
                assert(!(mask&(1u<<result)));
                for(int earlier=0;earlier<result;++earlier)assert(mask&(1u<<earlier));
            }
        }
    puts("PASS: free mode, empty-first placement, returning windows, full-layout replacement, layout shrink, switch cancellation and last-click wins.");
    return 0;
}
