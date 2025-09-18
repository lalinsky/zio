#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define MAX_COROUTINES 32
#define STACK_SIZE 8192

typedef enum {
    COROUTINE_READY,
    COROUTINE_RUNNING,
    COROUTINE_DEAD
} coroutine_state_t;

typedef struct {
    void *rsp;
    void *rbp;
    void *rbx;
    void *r12;
    void *r13;
    void *r14;
    void *r15;
    void *rip;
} context_t;

typedef struct {
    context_t context;
    char *stack;
    coroutine_state_t state;
    void (*func)(void);
} coroutine_t;

typedef struct {
    coroutine_t coroutines[MAX_COROUTINES];
    int current;
    int count;
    context_t main_context;
} scheduler_t;

static scheduler_t g_scheduler = {0};

static void save_context(context_t *ctx) {
    __asm__ volatile (
        "movq %%rsp, 0(%0)\n\t"
        "movq %%rbp, 8(%0)\n\t"
        "movq %%rbx, 16(%0)\n\t"
        "movq %%r12, 24(%0)\n\t"
        "movq %%r13, 32(%0)\n\t"
        "movq %%r14, 40(%0)\n\t"
        "movq %%r15, 48(%0)\n\t"
        "leaq 1f(%%rip), %%rax\n\t"
        "movq %%rax, 56(%0)\n\t"
        "1:\n\t"
        :
        : "r" (ctx)
        : "rax", "memory"
    );
}

static void restore_context(context_t *ctx) {
    __asm__ volatile (
        "movq 0(%0), %%rsp\n\t"
        "movq 8(%0), %%rbp\n\t"
        "movq 16(%0), %%rbx\n\t"
        "movq 24(%0), %%r12\n\t"
        "movq 32(%0), %%r13\n\t"
        "movq 40(%0), %%r14\n\t"
        "movq 48(%0), %%r15\n\t"
        "jmpq *56(%0)\n\t"
        :
        : "r" (ctx)
        : "memory"
    );
}


static void coroutine_wrapper(void) {
    coroutine_t *coro = &g_scheduler.coroutines[g_scheduler.current];
    coro->func();
    coro->state = COROUTINE_DEAD;
    restore_context(&g_scheduler.main_context);
}

int scheduler_spawn(void (*func)(void)) {
    if (g_scheduler.count >= MAX_COROUTINES) {
        return -1;
    }

    int id = g_scheduler.count++;
    coroutine_t *coro = &g_scheduler.coroutines[id];

    coro->stack = malloc(STACK_SIZE);
    if (!coro->stack) {
        g_scheduler.count--;
        return -1;
    }

    coro->func = func;
    coro->state = COROUTINE_READY;

    char *stack_top = coro->stack + STACK_SIZE;
    stack_top = (char*)((uintptr_t)stack_top & ~15UL);

    coro->context.rsp = stack_top;
    coro->context.rbp = stack_top;
    coro->context.rbx = 0;
    coro->context.r12 = 0;
    coro->context.r13 = 0;
    coro->context.r14 = 0;
    coro->context.r15 = 0;
    coro->context.rip = (void*)coroutine_wrapper;

    return id;
}

void scheduler_yield(void) {
    if (g_scheduler.current == -1) return;

    coroutine_t *current_coro = &g_scheduler.coroutines[g_scheduler.current];
    current_coro->state = COROUTINE_READY;

    save_context(&current_coro->context);
    restore_context(&g_scheduler.main_context);
}

void scheduler_run(void) {
    g_scheduler.current = -1;

    while (1) {
        int next = -1;
        for (int i = 0; i < g_scheduler.count; i++) {
            if (g_scheduler.coroutines[i].state == COROUTINE_READY) {
                next = i;
                break;
            }
        }

        if (next == -1) break;

        g_scheduler.current = next;
        g_scheduler.coroutines[next].state = COROUTINE_RUNNING;

        save_context(&g_scheduler.main_context);
        restore_context(&g_scheduler.coroutines[next].context);
    }

    for (int i = 0; i < g_scheduler.count; i++) {
        if (g_scheduler.coroutines[i].stack) {
            free(g_scheduler.coroutines[i].stack);
        }
    }
    g_scheduler.count = 0;
}

void task1(void) {
    for (int i = 0; i < 5; i++) {
        printf("Task 1: iteration %d\n", i);
        scheduler_yield();
    }
    printf("Task 1: finished\n");
}

void task2(void) {
    for (int i = 0; i < 3; i++) {
        printf("Task 2: iteration %d\n", i);
        scheduler_yield();
    }
    printf("Task 2: finished\n");
}

void task3(void) {
    for (int i = 0; i < 4; i++) {
        printf("Task 3: iteration %d\n", i);
        scheduler_yield();
    }
    printf("Task 3: finished\n");
}

int main(void) {
    printf("Starting coroutine demo\n");

    scheduler_spawn(task1);
    scheduler_spawn(task2);
    scheduler_spawn(task3);

    scheduler_run();

    printf("All coroutines finished\n");
    return 0;
}