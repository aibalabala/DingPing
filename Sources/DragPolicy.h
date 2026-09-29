#ifndef FIXED_SPLIT_DRAG_POLICY_H
#define FIXED_SPLIT_DRAG_POLICY_H
#include "Layout.h"

typedef enum { FSDragDown, FSDragMotion, FSDragUp, FSDragReset } FSDragEvent;
typedef struct { bool consuming; } FSDragState;

/* Only a DOWN confirmed to be in a protected title bar starts suppression.
   Content drags remain allowed even when they later cross a title bar. */
bool FSFilterDrag(FSDragState *state, FSDragEvent event, bool enabled, bool confirmedTitle);
bool FSTitleCandidate(FSRect window, double x, double y);
#endif
