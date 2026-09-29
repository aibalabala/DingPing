#ifndef FIXED_SPLIT_LAYOUT_H
#define FIXED_SPLIT_LAYOUT_H

#include <stdbool.h>

typedef struct { double x, y, width, height; } FSRect;
typedef enum {
    FSLayoutColumns2 = 0,
    FSLayoutColumns3,
    FSLayoutMainAndStack,
    FSLayoutGrid,
    FSLayoutRows2,
    FSLayoutFill,
    FSLayoutStackAndMain,
    FSLayoutMainTopAndColumns,
    FSLayoutRows3,
    FSLayoutMainAndThree,
    FSLayoutCount
} FSLayout;

/* All layout rectangles use desktop points and a top-left origin. */
int FSBuildZones(FSLayout layout, FSRect usable, double ratio, double gap, FSRect out[4]);
FSRect FSCocoaToAX(FSRect rect, double primaryScreenTop);
bool FSRectNear(FSRect a, FSRect b, double tolerance);
/* Area shared by a window and display, in desktop points. Invalid bounds return 0. */
double FSIntersectionArea(FSRect a, FSRect b);

#endif
