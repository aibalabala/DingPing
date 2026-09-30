#ifndef FS_BINDING_POLICY_H
#define FS_BINDING_POLICY_H
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    const char *bundle;
    const char *title;
    const char *document;
    bool used;
    bool restorable;
    bool visibleOnTarget;
} FSBindingCandidate;

typedef struct {
    const char *bundle;
    const char *title;
    const char *document;
    int previous; /* Index in candidate array, or -1. */
    bool pinned;
    bool borrowed;
} FSBindingSlot;

/* A document or exact title must identify one window. If neither does, one
   remaining window of that application is safe to recover across title edits. */
int FSBindingChoose(const char *bundle, const char *title, const char *document,
                    const FSBindingCandidate *candidates, size_t count,
                    bool allowSingleAppFallback);
/* Returns assignments and an owner mask. Missing fixed owners can be borrowed,
   but their saved descriptors remain unchanged and reclaim their slots later. */
unsigned FSBindingPlan(const FSBindingSlot *slots, int slotCount,
                       FSBindingCandidate *windows, size_t windowCount, int result[4]);
#endif
