#include "../Sources/Layout.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static int count;
static void check(bool test) { assert(test); count++; }
static bool overlap(FSRect a, FSRect b) {
    return fmin(a.x+a.width,b.x+b.width)>fmax(a.x,b.x) &&
           fmin(a.y+a.height,b.y+b.height)>fmax(a.y,b.y);
}

int main(void) {
    FSRect out[4];
    int n=FSBuildZones(FSLayoutColumns2,(FSRect){0,25,1440,835},.5,8,out);
    check(n==2);
    check(FSRectNear(out[0],(FSRect){8,33,708,819},0));
    check(FSRectNear(out[1],(FSRect){724,33,708,819},0));
    /* Retina coordinates stay in points; negative origins are not clamped. */
    FSRect left=FSCocoaToAX((FSRect){-1920,0,1920,1056},900);
    check(FSRectNear(left,(FSRect){-1920,-156,1920,1056},0));
    FSRect above=FSCocoaToAX((FSRect){0,900,1920,1056},900);
    check(FSRectNear(above,(FSRect){0,-1056,1920,1056},0));
    FSRect below=FSCocoaToAX((FSRect){0,-1080,1920,1056},900);
    check(FSRectNear(below,(FSRect){0,924,1920,1056},0));
    int expected[]={2,3,3,4,2,1,3,3,3,4};
    double widths[]={640,1280,1440,1512,1920,3440};
    double heights[]={480,720,982,1080,1440};
    double ratios[]={.2,.3333,.5,.667,.8};
    double gaps[]={0,1,8,24,40};
    for (int k=0;k<FSLayoutCount;k++) for(int w=0;w<6;w++)
    for(int h=0;h<5;h++) for(int r=0;r<5;r++) for(int g=0;g<5;g++) {
        FSRect a={-widths[w],-777,widths[w],heights[h]};
        n=FSBuildZones(k,a,ratios[r],gaps[g],out);
        check(n==expected[k]);
        for(int i=0;i<n;i++) {
            check(out[i].width>0 && out[i].height>0);
            check(out[i].x>=a.x && out[i].y>=a.y);
            check(out[i].x+out[i].width<=a.x+a.width);
            check(out[i].y+out[i].height<=a.y+a.height);
            for(int j=0;j<i;j++) check(!overlap(out[i],out[j]));
        }
    }
    n=FSBuildZones(FSLayoutColumns3,(FSRect){0,0,1440,900},.5,0,out);
    check(n==3 && out[0].width+out[1].width+out[2].width==1440);
    n=FSBuildZones(FSLayoutStackAndMain,(FSRect){0,0,1200,900},1.0/3.0,8,out);
    check(n==3 && out[0].x==out[1].x && out[2].x>out[0].x);
    check(out[2].height==out[0].height+8+out[1].height);
    /* Quick presets: equal left/right halves with either side split in two. */
    n=FSBuildZones(FSLayoutMainAndStack,(FSRect){0,0,1200,900},.5,8,out);
    check(n==3 && fabs(out[0].width-out[1].width)<=1);
    check(out[1].width==out[2].width && out[0].height==out[1].height+8+out[2].height);
    n=FSBuildZones(FSLayoutStackAndMain,(FSRect){0,0,1200,900},.5,8,out);
    check(n==3 && fabs(out[0].width-out[2].width)<=1);
    check(out[0].width==out[1].width && out[2].height==out[0].height+8+out[1].height);
    n=FSBuildZones(FSLayoutMainTopAndColumns,(FSRect){0,0,1200,900},2.0/3.0,8,out);
    check(n==3 && out[0].y<out[1].y && out[1].y==out[2].y);
    check(fabs(out[1].width-out[2].width)<=1);
    n=FSBuildZones(FSLayoutRows3,(FSRect){0,0,1200,900},.5,8,out);
    check(n==3 && out[0].y<out[1].y && out[1].y<out[2].y);
    n=FSBuildZones(FSLayoutMainAndThree,(FSRect){0,0,1200,900},2.0/3.0,8,out);
    check(n==4 && out[0].height==out[1].height+out[2].height+out[3].height+16);
    check(FSBuildZones(FSLayoutGrid,(FSRect){0,0,10,10},.5,8,out)==0);
    check(FSBuildZones(99,(FSRect){0,0,1000,1000},.5,8,out)==0);
    check(FSBuildZones(0,(FSRect){NAN,0,1000,1000},.5,8,out)==0);
    check(FSBuildZones(0,(FSRect){0,0,1000,1000},NAN,NAN,out)==2);
    /* Auto-fill must not pull windows from an adjacent screen. */
    FSRect primary={0,0,1440,900},external={-1920,0,1920,1080};
    FSRect straddling={-600,100,800,500};
    check(FSIntersectionArea(straddling,external)==300000);
    check(FSIntersectionArea(straddling,primary)==100000);
    check(FSIntersectionArea((FSRect){-1000,30,500,600},primary)==0);
    check(FSIntersectionArea((FSRect){-500,-500,1000,700},primary)==100000);
    check(FSIntersectionArea((FSRect){1440,0,500,600},primary)==0);
    check(FSIntersectionArea(primary,primary)==1440*900);
    check(FSIntersectionArea((FSRect){NAN,0,500,600},primary)==0);
    check(FSIntersectionArea((FSRect){0,0,-500,600},primary)==0);
    check(FSIntersectionArea(primary,(FSRect){0,0,INFINITY,900})==0);
    check(FSIntersectionArea(straddling,primary)==FSIntersectionArea(primary,straddling));
    printf("PASS: %d geometry assertions; ten layouts, ratios, gaps, multi-display coordinates.\n",count);
    return 0;
}
