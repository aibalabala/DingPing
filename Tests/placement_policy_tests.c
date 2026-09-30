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
    assert(FSPlacementChooseAvailableSlot(&state,2,-1,0,1)==1); /* Present owner stays reserved. */
    assert(FSPlacementChooseAvailableSlot(&state,2,-1,0,0)==0); /* Missing owner can be borrowed. */
    assert(FSPlacementChooseAvailableSlot(&state,2,0,3,1)==1); /* Old history cannot evict pin. */
    assert(FSPlacementChooseAvailableSlot(&state,2,-1,3,3)==-1); /* No replaceable slot. */
    assert(FSPlacementChooseAvailableSlot(&state,4,-1,15,11u)==2);
    assert(FSPlacementChooseAvailableSlot(&state,4,2,15,11u)==2);
    assert(FSPlacementChooseNewWindowSlot(&state,3,1,3u,0,true)==1); /* New window replaces active despite an empty third slot. */
    assert(FSPlacementChooseNewWindowSlot(&state,3,1,3u,0,false)==2); /* Existing windows still fill empty slots. */
    assert(FSPlacementChooseNewWindowSlot(&state,3,0,1u,1u,true)==1); /* Active pin is reserved. */
    assert(FSPlacementChooseNewWindowSlot(&state,3,-1,1u,0,true)==1); /* No active zone: ordinary placement. */
    state.lastSlot=0;
    assert(FSPlacementChooseAvailableSlot(&state,3,-1,7,1)==1);
    state.lastSlot=3;
    assert(FSPlacementChooseSlot(&state,2,3,3)==0); /* Four -> two, no out of bounds. */
    assert(FSPlacementChooseSlot(&state,0,-1,0)==-1);
    assert(FSPlacementChooseSlot(&state,5,-1,0)==-1);
    uint64_t first=FSPlacementBeginSwitch(&state);
    assert(FSPlacementChooseSlot(&state,2,-1,0)==-1); /* Internal focus is suppressed. */
    assert(FSPlacementChooseNewWindowSlot(&state,2,1,0,0,true)==-1);
    uint64_t last=FSPlacementBeginSwitch(&state);
    assert(!FSPlacementFinishSwitch(&state,first)); /* Last click wins. */
    assert(FSPlacementSwitchIsCurrent(&state,last));
    assert(FSPlacementFinishSwitch(&state,last));
    assert(!FSPlacementFinishSwitch(&state,last));
    first=FSPlacementBeginSwitch(&state);
    FSPlacementSetEnabled(&state,false);
    assert(!FSPlacementFinishSwitch(&state,first)); /* Free mode cancels queued work. */
    assert(FSPlacementChooseSlot(&state,2,1,3)==-1);
    assert(FSPlacementChooseNewWindowSlot(&state,2,1,3,0,true)==-1);
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
    for(int count=1;count<=4;++count)for(unsigned pins=0;pins<16;++pins)
        for(unsigned occupied=0;occupied<16;++occupied)for(int known=-1;known<5;++known) {
            int chosen=FSPlacementChooseAvailableSlot(&state,count,known,occupied,pins);
            unsigned active=(1u<<count)-1u;
            if((pins&active)==active)assert(chosen==-1);
            else {
                assert(chosen>=0 && chosen<count && !(pins&(1u<<chosen)));
                if(known>=0 && known<count && !(pins&(1u<<known)))assert(chosen==known);
            }
        }
    puts("PASS: free mode, pin reservations, new-window active slot, empty-first existing windows, layout shrink, switch cancellation.");
    return 0;
}
