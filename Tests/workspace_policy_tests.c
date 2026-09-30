#include "../Sources/WorkspacePolicy.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    FSWorkspaceGate gate={0};FSWorkspaceEnable(&gate,true);
    uint64_t oldMove=gate.generation,drag=FSWorkspaceBeginDrag(&gate);
    assert(drag && !FSWorkspaceIdle(&gate));
    assert(!FSWorkspaceCommandCurrent(&gate,oldMove));
    assert(!FSWorkspaceBeginSwitch(&gate)); /* Switch queues, never invalidates drag. */
    assert(FSWorkspaceReleaseDrag(&gate,drag));
    assert(!FSWorkspaceIdle(&gate) && !FSWorkspaceBeginSwitch(&gate));
    assert(!FSWorkspaceFinishDrag(&gate,drag-1));
    assert(FSWorkspaceFinishDrag(&gate,drag) && FSWorkspaceIdle(&gate));
    assert(!FSWorkspaceFinishDrag(&gate,drag)); /* Exactly one commit. */
    uint64_t layout=FSWorkspaceBeginSwitch(&gate);
    assert(layout && !FSWorkspaceIdle(&gate));
    assert(!FSWorkspaceFinishSwitch(&gate,layout-1));
    assert(FSWorkspaceFinishSwitch(&gate,layout));
    assert(!FSWorkspaceCommandCurrent(&gate,drag));
    drag=FSWorkspaceBeginDrag(&gate);assert(drag);
    FSWorkspaceEnable(&gate,false);
    assert(!FSWorkspaceFinishDrag(&gate,drag) && !FSWorkspaceCommandCurrent(&gate,layout));
    assert(!FSWorkspaceBeginDrag(&gate));
    unsigned checks=0;
    for(int count=1;count<=4;count++)for(unsigned a=0;a<5;a++)for(unsigned b=0;b<5;b++)
    for(unsigned c=0;c<5;c++)for(unsigned d=0;d<5;d++) {
        unsigned populations[4]={a,b,c,d};
        for(int known=0;known<count;known++)for(int active=-1;active<count;active++) {
            assert(FSWorkspaceChooseSlot(count,known,active,populations,true)==known);
            assert(FSWorkspaceChooseSlot(count,known,active,populations,false)==known);checks+=2;
        }
        int next=FSWorkspaceChooseSlot(count,-1,-1,populations,false);
        assert(next>=0 && next<count);
        for(int i=0;i<count;i++){assert(populations[next]<=populations[i]);}
        checks++;
    }
    unsigned population[4]={0};
    for(unsigned i=0;i<1000;i++)population[FSWorkspaceChooseSlot(3,-1,1,population,false)]++;
    assert(population[0]+population[1]+population[2]==1000); /* No replacement or capacity limit. */
    assert(population[0]==334 && population[1]==333 && population[2]==333);
    assert(FSWorkspaceChooseSlot(3,-1,2,population,true)==2);
    assert(FSWorkspaceChooseSlot(0,0,0,population,false)==-1);
    printf("PASS: %u stable membership decisions; drag priority, queued switch, stale commands, overflow stacks.\n",checks);
    return 0;
}
