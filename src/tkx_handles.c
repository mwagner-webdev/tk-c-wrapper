/*
 * tkx_handles.c -- generational handle registry (handwritten).
 *
 * Why handwritten: handle allocation and invalidation are runtime
 * mechanisms with no counterpart in Tk's sources.
 *
 * A handle encodes slot index, slot generation, application serial and
 * object kind (see tkx.h).  A slot's generation is incremented every time
 * the slot is released, so a stale handle never matches again.  When a
 * slot's generation reaches its maximum the slot is retired instead of
 * wrapping around.  The table lives for the whole process: generations
 * are never reset, and the application serial changes with every
 * tkx_app_init(), so handles from an earlier application are rejected
 * even if a slot generation happened to match.
 *
 * All functions run on the UI thread (callers check), except the pure
 * decoding helpers.
 */
#include "tkx_internal.h"
#include <stdlib.h>

typedef struct Slot {
    uint32_t generation;    /* current generation (starts at 1) */
    uint8_t kind;           /* kind of the live object, 0 if free */
    uint8_t retired;
    void *object;
} Slot;

static Slot *slots = NULL;
static uint32_t slotCount = 0;     /* slots in use or free (high water) */
static uint32_t slotCap = 0;
static uint32_t *freeList = NULL;
static uint32_t freeCount = 0;
static uint32_t freeCap = 0;
static unsigned appSerial = 0;     /* 1..255 */

static TkxId
Encode(uint32_t index, uint32_t gen, unsigned serial, int kind)
{
    return ((TkxId)(kind & 0xFF) << 56) | ((TkxId)(serial & 0xFF) << 48)
	| ((TkxId)(gen & TKX__GEN_MASK) << 24) | (TkxId)(index & TKX__INDEX_MASK);
}

int
tkx_handle_kind(TkxId id)
{
    return (int)((id >> 56) & 0xFF);
}

uint32_t
tkx_handle_index(TkxId id)
{
    return (uint32_t)(id & TKX__INDEX_MASK);
}

uint32_t
tkx_handle_generation(TkxId id)
{
    return (uint32_t)((id >> 24) & TKX__GEN_MASK);
}

static unsigned
HandleSerial(TkxId id)
{
    return (unsigned)((id >> 48) & 0xFF);
}

unsigned
tkx__app_serial(void)
{
    return appSerial;
}

void
tkx__next_app_serial(void)
{
    appSerial = (appSerial % 255) + 1;
}

TkxId
tkx__handle_alloc(int kind, void *object)
{
    uint32_t index;

    if (kind <= 0 || kind > 255) {
	tkx__error(TKX_ERR_INVALID_ARGUMENT, "invalid object kind %d", kind);
	return TKX_NULL_ID;
    }
    if (freeCount > 0) {
	index = freeList[--freeCount];
    } else {
	if (slotCount > TKX__INDEX_MASK) {
	    tkx__error(TKX_ERR_NO_MEMORY, "handle table full");
	    return TKX_NULL_ID;
	}
	if (slotCount == slotCap) {
	    uint32_t ncap = slotCap ? slotCap * 2 : 64;
	    Slot *ns = (Slot *)realloc(slots, sizeof(Slot) * ncap);
	    if (ns == NULL) {
		tkx__error(TKX_ERR_NO_MEMORY, "out of memory");
		return TKX_NULL_ID;
	    }
	    slots = ns;
	    slotCap = ncap;
	}
	index = slotCount++;
	slots[index].generation = 1;
	slots[index].retired = 0;
    }
    slots[index].kind = (uint8_t)kind;
    slots[index].object = object;
    return Encode(index, slots[index].generation, appSerial, kind);
}

void *
tkx__handle_lookup(TkxId id, int kind, TkxStatus *status)
{
    uint32_t index = tkx_handle_index(id);
    int hkind = tkx_handle_kind(id);
    Slot *s;

    if (id == TKX_NULL_ID || hkind == 0 || HandleSerial(id) != appSerial
	    || index >= slotCount) {
	*status = TKX_ERR_INVALID_HANDLE;
	return NULL;
    }
    s = &slots[index];
    if (s->kind == 0 || s->generation != tkx_handle_generation(id)) {
	*status = (tkx_handle_generation(id) < s->generation
		|| (s->kind == 0 && tkx_handle_generation(id) == s->generation))
		? TKX_ERR_STALE_HANDLE : TKX_ERR_INVALID_HANDLE;
	return NULL;
    }
    if (s->kind != hkind) {
	/* Kind bits do not match the slot: forged or corrupted handle. */
	*status = TKX_ERR_INVALID_HANDLE;
	return NULL;
    }
    if (kind != 0 && hkind != kind) {
	*status = TKX_ERR_WRONG_KIND;
	return NULL;
    }
    *status = TKX_OK;
    return s->object;
}

void
tkx__handle_release(TkxId id)
{
    uint32_t index = tkx_handle_index(id);
    Slot *s;

    if (index >= slotCount) {
	return;
    }
    s = &slots[index];
    if (s->kind == 0 || s->generation != tkx_handle_generation(id)) {
	return;
    }
    s->kind = 0;
    s->object = NULL;
    if (s->generation >= TKX__GEN_MASK) {
	s->retired = 1;          /* never reuse: would wrap around */
	return;
    }
    s->generation++;
    if (freeCount == freeCap) {
	uint32_t ncap = freeCap ? freeCap * 2 : 64;
	uint32_t *nf = (uint32_t *)realloc(freeList, sizeof(uint32_t) * ncap);
	if (nf == NULL) {
	    return;              /* slot leaks, but stays invalid */
	}
	freeList = nf;
	freeCap = ncap;
    }
    freeList[freeCount++] = index;
}

void
tkx__handles_reset_all(void)
{
    uint32_t i;

    for (i = 0; i < slotCount; i++) {
	if (slots[i].kind != 0) {
	    tkx__handle_release(Encode(i, slots[i].generation, appSerial,
		    slots[i].kind));
	}
    }
}

int
tkx_handle_is_valid(TkxId id)
{
    TkxStatus st;

    if (tkx__enter() != TKX_OK) {
	return 0;
    }
    return tkx__handle_lookup(id, 0, &st) != NULL;
}
