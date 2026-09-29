#ifndef FIXED_SPLIT_DRAG_POLICY_H
#define FIXED_SPLIT_DRAG_POLICY_H
#include "Layout.h"

typedef enum { FSDragDown, FSDragMotion, FSDragUp, FSDragReset } FSDragEvent;
typedef struct { bool consuming; } FSDragState;

/* Only a DOWN confirmed to be in a protected title bar starts suppression.
   Content drags remain allowed even when they later cross a title bar. */
bool FSFilterDrag(FSDragState *state, FSDragEvent event, bool enabled, bool confirmedTitle);
bool FSTitleCandidate(FSRect window, double x, double y);
/* Passive drag detection may watch a larger toolbar area because it only acts
   after the actual window frame has moved. The active blocker stays strict. */
bool FSPassiveDragCandidate(FSRect window, double x, double y);

typedef enum { FSDropIgnore, FSDropBlocked, FSDropMove, FSDropSwap, FSDropReplace } FSDropAction;
/* A genuine title-bar translation can change assignments; resizing cannot. */
bool FSWindowWasDragged(FSRect before, FSRect after);
/* macOS may resize a window while moving it; this remains a drag when the
   gesture began in the interior of the title bar. */
bool FSWindowTitleMoved(FSRect before,FSRect after,double downX,double downY);
/* A managed window can be assigned by a deliberate title-bar drop even if the
   target app restores its frame before accessibility reports the final move. */
bool FSPointerDragIntent(FSRect sourceWindow,int source,bool plainChrome,
                         double downX,double downY,double upX,double upY);
int FSDropZoneAt(const FSRect zones[4], int count, double x, double y);
/* A window moved into another zone can be dropped while its grab point remains
   inside the old zone; a drop outside all zones still cancels reassignment. */
int FSDropDestination(const FSRect zones[4], int count, int source,
                      double mouseX, double mouseY, FSRect droppedWindow);
FSDropAction FSDropChooseAction(int count, int source, int target,
                                unsigned pinned, bool targetOccupied);
#endif
