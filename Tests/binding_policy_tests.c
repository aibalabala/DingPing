#include "../Sources/BindingPolicy.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    FSBindingCandidate w[]={
        {.bundle="chrome",.title="New tab",.document="https://old"},
        {.bundle="code",.title="project changed"},
        {.bundle="terminal",.title="shell"}
    };
    assert(FSBindingChoose("chrome","old title","https://old",w,3,false)==0);
    assert(FSBindingChoose("code","old project",NULL,w,3,false)==-1);
    assert(FSBindingChoose("code","old project",NULL,w,3,true)==1);
    w[1].used=true;
    assert(FSBindingChoose("code","old project",NULL,w,3,true)==-1);
    w[1].used=false;
    FSBindingCandidate two[]={
        {.bundle="chrome",.title="first",.document="https://a"},
        {.bundle="chrome",.title="second",.document="https://b"}
    };
    assert(FSBindingChoose("chrome","missing",NULL,two,2,true)==-1);
    assert(FSBindingChoose("chrome","second",NULL,two,2,false)==1);
    assert(FSBindingChoose("chrome","missing","https://a",two,2,false)==0);
    two[1].used=true;
    assert(FSBindingChoose("chrome","missing",NULL,two,2,true)==0);
    two[1].used=false;two[1].title="first";
    assert(FSBindingChoose("chrome","first",NULL,two,2,false)==-1);
    FSBindingSlot slots[]={
        {.bundle="chrome",.title="old tab",.previous=-1,.pinned=true},
        {.bundle="code",.title="old project",.previous=-1,.pinned=true},
        {.bundle="terminal",.title="shell",.previous=-1}
    };
    FSBindingCandidate missing[]={
        {.bundle="finder",.title="files",.restorable=true,.visibleOnTarget=true},
        {.bundle="terminal",.title="shell",.restorable=true,.visibleOnTarget=true},
        {.bundle="notes",.title="notes",.restorable=true,.visibleOnTarget=true}
    };
    int result[4];
    assert(FSBindingPlan(slots,3,missing,3,result)==0);
    assert(result[0]==0 && result[1]==2 && result[2]==1); /* Both empty pins borrowed. */
    FSBindingCandidate returned[]={
        {.bundle="finder",.title="files",.restorable=true,.visibleOnTarget=true},
        {.bundle="terminal",.title="shell",.restorable=true,.visibleOnTarget=true},
        {.bundle="chrome",.title="new tab",.restorable=true,.visibleOnTarget=true},
        {.bundle="code",.title="new project",.restorable=true,.visibleOnTarget=true}
    };
    slots[0].previous=0;slots[0].borrowed=true;
    slots[1].previous=-1;slots[2].previous=1;
    assert(FSBindingPlan(slots,3,returned,4,result)==3u);
    assert(result[0]==2 && result[1]==3 && result[2]==1); /* Owners reclaim slots. */
    FSBindingCandidate ambiguous[]={
        {.bundle="chrome",.title="tab A",.restorable=true,.visibleOnTarget=true},
        {.bundle="chrome",.title="tab B",.restorable=true,.visibleOnTarget=true},
        {.bundle="code",.title="new project",.restorable=true,.visibleOnTarget=true}
    };
    slots[0].previous=-1;slots[0].borrowed=false;
    assert(FSBindingPlan(slots,3,ambiguous,3,result)==2u);
    assert(result[1]==2 && result[0]!=2); /* Ambiguous Chrome does not acquire a pin. */
    FSBindingCandidate live[]={
        {.bundle="chrome",.title="changed",.restorable=true,.visibleOnTarget=true},
        {.bundle="chrome",.title="another",.restorable=true,.visibleOnTarget=true}
    };
    slots[0].previous=0;slots[0].borrowed=false;
    assert((FSBindingPlan(slots,3,live,2,result)&1u)!=0 && result[0]==0);
    /* An absent Code pin's borrowed zone holds Terminal. Re-resolving must
       keep this current occupant, then restore Code when it returns. */
    FSBindingSlot dragged[]={
        {.bundle="chrome",.title="browser",.previous=0,.pinned=true},
        {.bundle="code",.title="editor",.previous=2,.pinned=true,.borrowed=true},
        {.bundle="finder",.title="files",.previous=1}
    };
    FSBindingCandidate afterDrop[]={
        {.bundle="chrome",.title="browser",.restorable=true,.visibleOnTarget=true},
        {.bundle="finder",.title="files",.restorable=true,.visibleOnTarget=true},
        {.bundle="terminal",.title="shell",.restorable=true,.visibleOnTarget=true}
    };
    assert(FSBindingPlan(dragged,3,afterDrop,3,result)==1u);
    assert(result[0]==0 && result[1]==2 && result[2]==1);
    FSBindingCandidate codeReturns[]={
        {.bundle="chrome",.title="browser",.restorable=true,.visibleOnTarget=true},
        {.bundle="finder",.title="files",.restorable=true,.visibleOnTarget=true},
        {.bundle="terminal",.title="shell",.restorable=true,.visibleOnTarget=true},
        {.bundle="code",.title="editor",.restorable=true,.visibleOnTarget=true}
    };
    assert(FSBindingPlan(dragged,3,codeReturns,4,result)==3u);
    assert(result[0]==0 && result[1]==3 && result[2]==1);
    FSBindingSlot horizontal[]={
        {.bundle="chrome",.title="Codex",.previous=1},
        {.bundle="chrome",.title="fixed browser",.previous=0,.pinned=true},
        {.bundle="finder",.title="files",.previous=2}
    };
    FSBindingCandidate exchanged[]={
        {.bundle="chrome",.title="fixed browser",.restorable=true,.visibleOnTarget=true},
        {.bundle="chrome",.title="Codex",.restorable=true,.visibleOnTarget=true},
        {.bundle="finder",.title="files",.restorable=true,.visibleOnTarget=true}
    };
    assert(FSBindingPlan(horizontal,3,exchanged,3,result)==2u);
    assert(result[0]==1 && result[1]==0 && result[2]==2); /* Resolver preserves manual left/right swap. */
    for(int i=0;i<3;i++){horizontal[i].previous=-1;exchanged[i].used=false;}
    assert(FSBindingPlan(horizontal,3,exchanged,3,result)==2u);
    assert(result[0]==1 && result[1]==0 && result[2]==2); /* Restart resolves pin in its new slot. */
    puts("PASS: missing/returning pins, borrowed stability, same-app manual swap resolves after restart, ambiguity.");
    return 0;
}
