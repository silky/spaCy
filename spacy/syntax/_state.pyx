# cython: profile=True
from libc.string cimport memmove, memcpy
from cymem.cymem cimport Pool

from ..lexeme cimport EMPTY_LEXEME
from ..structs cimport TokenC, Entity, Constituent


DEF PADDING = 5
DEF NON_MONOTONIC = True


cdef int add_dep(State *s, int head, int child, int label) except -1:
    if has_head(&s.sent[child]):
        del_dep(s, child + s.sent[child].head, child)
    cdef int dist = head - child
    s.sent[child].head = dist
    s.sent[child].dep = label
    if child > head:
        s.sent[head].r_kids += 1
        s.sent[head].r_edge = child - head
        # Walk up the tree, setting right edge
        n_iter = 0
        start = head
        while s.sent[head].head != 0:
            head += s.sent[head].head
            s.sent[head].r_edge = child - head
            n_iter += 1
            if n_iter >= s.sent_len:
                tree = [(i + s.sent[i].head) for i in range(s.sent_len)]
                msg = "Error adding dependency (%d, %d). Could not find root of tree: %s"
                msg = msg % (start, child, tree)
                raise Exception(msg)
    else:
        s.sent[head].l_kids += 1
        s.sent[head].l_edge = (child + s.sent[child].l_edge) - head


cdef int del_dep(State *s, int head, int child) except -1:
    cdef const TokenC* next_child
    cdef int dist = head - child
    if child > head:
        s.sent[head].r_kids -= 1
        next_child = get_right(s, &s.sent[head], 1)
        if next_child == NULL:
            s.sent[head].r_edge = 0
        else:
            s.sent[head].r_edge = next_child.r_edge
    else:
        s.sent[head].l_kids -= 1
        next_child = get_left(s, &s.sent[head], 1)
        if next_child == NULL:
            s.sent[head].l_edge = 0
        else:
            s.sent[head].l_edge = next_child.l_edge


cdef int pop_stack(State *s) except -1:
    assert s.stack_len >= 1
    s.stack_len -= 1
    s.stack -= 1
    if s.stack_len == 0 and not at_eol(s):
        push_stack(s)


cdef int push_stack(State *s) except -1:
    assert s.i < s.sent_len
    s.stack += 1
    s.stack[0] = s.i
    s.stack_len += 1
    s.i += 1


cdef int children_in_buffer(const State *s, int head, const int* gold) except -1:
    # Golds holds an array of head offsets --- the head of word i is i - golds[i]
    # Iterate over the tokens of the queue, and check whether their gold head is
    # our target
    cdef int i
    cdef int n = 0
    for i in range(s.i, s.sent_len):
        if gold[i] == head:
            n += 1
        elif gold[i] == i or gold[i] < head:
            break
    return n


cdef int head_in_buffer(const State *s, const int child, const int* gold) except -1:
    return gold[child] >= s.i


cdef int children_in_stack(const State *s, const int head, const int* gold) except -1:
    cdef int i
    cdef int n = 0
    for i in range(s.stack_len):
        if gold[s.stack[-i]] == head:
            if NON_MONOTONIC or not has_head(get_s0(s)):
                n += 1
    return n


cdef int head_in_stack(const State *s, const int child, const int* gold) except -1:
    cdef int i
    for i in range(s.stack_len):
        if gold[child] == s.stack[-i]:
            return 1
    return 0


cdef bint has_head(const TokenC* t) nogil:
    return t.head != 0


cdef const TokenC* get_left(const State* s, const TokenC* target, int idx) nogil:
    if target.l_kids == 0:
        return NULL
    if idx > target.l_kids:
        return NULL
    if idx < 1:
        return NULL
    cdef const TokenC* ptr = s.sent
    while ptr < target:
        # If this head is still to the right of us, we can skip to it
        # No token that's between this token and this head could be our
        # child.
        if (ptr.head >= 1) and (ptr + ptr.head) < target:
            ptr += ptr.head
        elif ptr + ptr.head == target:
            idx -= 1
            if idx == 0:
                return ptr
            ptr += 1
        else:
            ptr += 1
    return NULL


cdef const TokenC* get_right(const State* s, const TokenC* target, int idx) nogil:
    if target.r_kids == 0:
        return NULL
    if idx > target.r_kids:
        return NULL
    if idx < 1:
        return NULL
    cdef const TokenC* ptr = s.sent + (s.sent_len - 1)
    while ptr > target:
        # If this head is still to the right of us, we can skip to it
        # No token that's between this token and this head could be our
        # child.
        if (ptr.head < 0) and ((ptr + ptr.head) > target):
            ptr += ptr.head
        elif ptr + ptr.head == target:
            idx -= 1
        if idx == 0:
            return ptr
            ptr -= 1
        else:
            ptr -= 1
    return NULL


cdef int count_left_kids(const TokenC* head) nogil:
    return head.l_kids


cdef int count_right_kids(const TokenC* head) nogil:
    return head.r_kids


cdef State* new_state(Pool mem, const TokenC* sent, const int sent_len) except NULL:
    cdef int padded_len = sent_len + PADDING + PADDING
    cdef State* s = <State*>mem.alloc(1, sizeof(State))
    #s.ctnt = <Constituent*>mem.alloc(padded_len, sizeof(Constituent))
    s.ent = <Entity*>mem.alloc(padded_len, sizeof(Entity))
    s.stack = <int*>mem.alloc(padded_len, sizeof(int))
    for i in range(PADDING):
        s.stack[i] = -1
    #s.ctnt += (PADDING -1)
    s.stack += (PADDING - 1)
    s.ent += (PADDING - 1)
    assert s.stack[0] == -1
    state_sent = <TokenC*>mem.alloc(padded_len, sizeof(TokenC))
    memcpy(state_sent, sent - PADDING, padded_len * sizeof(TokenC))
    s.sent = state_sent + PADDING
    s.stack_len = 0
    s.i = 0
    s.sent_len = sent_len
    return s


cdef int copy_state(State* dest, const State* src) except -1:
    cdef int i
    # Copy stack --- remember stack uses pointer arithmetic, so stack[-stack_len]
    # is the last word of the stack.
    dest.stack += (src.stack_len - dest.stack_len)
    for i in range(src.stack_len):
        dest.stack[-i] = src.stack[-i]
    dest.stack_len = src.stack_len 
    # Copy sentence (i.e. the parse), up to and including word i.
    if src.i > dest.i:
        memcpy(dest.sent, src.sent, sizeof(TokenC) * (src.i+1))
    else:
        memcpy(dest.sent, src.sent, sizeof(TokenC) * (dest.i+1))
    dest.i = src.i
    # Copy assigned entities --- also pointer arithmetic
    dest.ent += (src.ents_len - dest.ents_len)
    for i in range(src.ents_len):
        dest.ent[-i] = src.ent[-i]
    dest.ents_len = src.ents_len
