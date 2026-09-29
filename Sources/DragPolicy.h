#ifndef FIXED_SPLIT_DRAG_POLICY_H
#define FIXED_SPLIT_DRAG_POLICY_H
#include "Layout.h"

typedef enum { FSDragDown, FSDragMotion, FSDragUp, FSDragReset } FSDragEvent;
typedef struct { bool consuming; } FSDragState;

/* Only a DOWN confirmed to be in a protected title bar starts suppression.
   Content drags remain allowed even when they later cross a title bar. */
bool FSFilterDrag(FSDragState *state, FSDragEvent event, bool enabled, bool confirmedTitle);
bool FSTitleCandidate(FSRect window, double x, double y);

typedef enum { FSDropIgnore, FSDropBlocked, FSDropMove, FSDropSwap, FSDropReplace } FSDropAction;
/* A genuine title-bar translation can change assignments; resizing cannot. */
bool FSWindowWasDragged(FSRect before, FSRect after);
int FSDropZoneAt(const FSRect zones[4], int count, double x, double y);
FSDropAction FSDropChooseAction(int count, int source, int target,
                                unsigned pinned, bool targetOccupied);
#endif
