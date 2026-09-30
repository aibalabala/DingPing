#include "BindingPolicy.h"
#include <string.h>

static bool same(const char *a, const char *b) {
    return a && b && *a && *b && strcmp(a,b)==0;
}

int FSBindingChoose(const char *bundle,const char *title,const char *document,
                    const FSBindingCandidate *candidates,size_t count,bool allowSingleAppFallback) {
    if(!bundle || !*bundle || !candidates)return -1;
    for(int rank=3;rank>=1;--rank) {
        if(rank==1 && !allowSingleAppFallback)break;
        int match=-1;
        for(size_t i=0;i<count;++i) {
            const FSBindingCandidate *w=&candidates[i];
            if(w->used || !same(bundle,w->bundle) ||
               (rank==3 && !same(document,w->document)) ||
               (rank==2 && !same(title,w->title)))continue;
            if(match!=-1){match=-1;break;} /* Ambiguous at this strength. */
            match=(int)i;
        }
        if(match>=0)return match;
    }
    return -1;
}

unsigned FSBindingPlan(const FSBindingSlot *slots,int slotCount,
                       FSBindingCandidate *windows,size_t windowCount,int result[4]) {
    if(!slots || !windows || !result || slotCount<1 || slotCount>4)return 0;
    for(int i=0;i<4;i++)result[i]=-1;
    unsigned owners=0;
    /* Live AX identity is stronger than a changed title or document. */
    for(int i=0;i<slotCount;i++)if(slots[i].pinned && !slots[i].borrowed &&
        slots[i].previous>=0 && (size_t)slots[i].previous<windowCount) {
        int index=slots[i].previous;
        if(!windows[index].used && windows[index].restorable) {
            result[i]=index;windows[index].used=true;owners|=1u<<i;
        }
    }
    /* Resolve all exact owners before the single-app fallback: two fixed
       windows of one app may have only one surviving exact title. */
    for(int phase=0;phase<2;phase++)for(int i=0;i<slotCount;i++)if(slots[i].pinned && result[i]<0) {
        int index=FSBindingChoose(slots[i].bundle,slots[i].title,slots[i].document,
                                  windows,windowCount,phase!=0);
        if(index>=0 && windows[index].restorable) {
            result[i]=index;windows[index].used=true;owners|=1u<<i;
        }
    }
    for(int i=0;i<slotCount;i++)if(!slots[i].pinned) {
        int index=slots[i].previous;
        if(index<0 || (size_t)index>=windowCount || windows[index].used ||
           !windows[index].restorable)
            index=FSBindingChoose(slots[i].bundle,slots[i].title,slots[i].document,
                                  windows,windowCount,false);
        if(index>=0 && windows[index].restorable) {
            result[i]=index;windows[index].used=true;
        }
    }
    for(size_t index=0;index<windowCount;index++)if(!windows[index].used && windows[index].visibleOnTarget) {
        for(int slot=0;slot<slotCount;slot++)if(result[slot]<0) {
            result[slot]=(int)index;windows[index].used=true;break;
        }
    }
    return owners;
}
