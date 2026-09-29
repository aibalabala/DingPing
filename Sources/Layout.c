#include "Layout.h"
#include <math.h>

static double clamp(double x, double lo, double hi) { return fmin(hi, fmax(lo, x)); }
static FSRect rect(double x, double y, double w, double h) { return (FSRect){x,y,w,h}; }

FSRect FSCocoaToAX(FSRect r, double top) {
    return rect(r.x, top - r.y - r.height, r.width, r.height);
}

bool FSRectNear(FSRect a, FSRect b, double t) {
    return fabs(a.x-b.x)<=t && fabs(a.y-b.y)<=t &&
           fabs(a.width-b.width)<=t && fabs(a.height-b.height)<=t;
}

double FSIntersectionArea(FSRect a, FSRect b) {
    if(!isfinite(a.x) || !isfinite(a.y) || !isfinite(b.x) || !isfinite(b.y) ||
       !isfinite(a.width) || !isfinite(a.height) || !isfinite(b.width) || !isfinite(b.height) ||
       a.width<=0 || a.height<=0 || b.width<=0 || b.height<=0 ||
       !isfinite(a.x+a.width) || !isfinite(a.y+a.height) ||
       !isfinite(b.x+b.width) || !isfinite(b.y+b.height))return 0;
    double w=fmax(0,fmin(a.x+a.width,b.x+b.width)-fmax(a.x,b.x));
    double h=fmax(0,fmin(a.y+a.height,b.y+b.height)-fmax(a.y,b.y));
    double area=w*h;return isfinite(area)?area:0;
}

int FSBuildZones(FSLayout kind, FSRect area, double ratio, double gap, FSRect out[4]) {
    if (!out || kind < 0 || kind >= FSLayoutCount ||
        !isfinite(area.x) || !isfinite(area.y) || !isfinite(area.width) ||
        !isfinite(area.height) || area.width < 40 || area.height < 40) return 0;
    ratio = isfinite(ratio) ? clamp(ratio, .2, .8) : .5;
    gap = isfinite(gap) ? floor(clamp(gap, 0, fmin(40, fmin(area.width,area.height)/12))) : 8;
    double x = ceil(area.x) + gap, y = ceil(area.y) + gap;
    double w = floor(area.x + area.width) - x - gap;
    double h = floor(area.y + area.height) - y - gap;
    double left = floor((w-gap)*ratio), right = w-gap-left;
    double top = floor((h-gap)*ratio), bottom = h-gap-top;
    switch (kind) {
        case FSLayoutColumns2:
            out[0]=rect(x,y,left,h); out[1]=rect(x+left+gap,y,right,h); return 2;
        case FSLayoutColumns3: {
            double a=floor((w-2*gap)/3), b=floor((w-2*gap-a)/2), c=w-2*gap-a-b;
            out[0]=rect(x,y,a,h); out[1]=rect(x+a+gap,y,b,h);
            out[2]=rect(x+a+b+2*gap,y,c,h); return 3;
        }
        case FSLayoutMainAndStack: {
            double half=floor((h-gap)/2);
            out[0]=rect(x,y,left,h); out[1]=rect(x+left+gap,y,right,half);
            out[2]=rect(x+left+gap,y+half+gap,right,h-gap-half); return 3;
        }
        case FSLayoutGrid: {
            double half=floor((h-gap)/2);
            out[0]=rect(x,y,left,half); out[1]=rect(x+left+gap,y,right,half);
            out[2]=rect(x,y+half+gap,left,h-gap-half);
            out[3]=rect(x+left+gap,y+half+gap,right,h-gap-half); return 4;
        }
        case FSLayoutRows2:
            out[0]=rect(x,y,w,top); out[1]=rect(x,y+top+gap,w,bottom); return 2;
        case FSLayoutFill:
            out[0]=rect(x,y,w,h); return 1;
        default: return 0;
    }
}
