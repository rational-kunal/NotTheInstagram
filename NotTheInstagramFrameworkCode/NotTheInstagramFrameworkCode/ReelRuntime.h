#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <string.h>

// Private runtime integration shared by the reel features. Never override a
// superclass in place, and validate the complete ABI before installing a group.
typedef struct {
    const char *selector;
    IMP replacement;
    IMP *original;
    const char *returnType;
    unsigned int argumentCount;
    const char *argumentTypes[6];
} NTIReelHook;

static inline BOOL NTIReelMethodMatches(Method method, const char *result,
                                      unsigned int count, const char *const *arguments) {
    if (!method || method_getNumberOfArguments(method) != count + 2) return NO;
    char type[128];
    method_getReturnType(method, type, sizeof(type));
    if (strcmp(type, result)) return NO;
    for (unsigned int i = 0; i < count; i++) {
        method_getArgumentType(method, i + 2, type, sizeof(type));
        if (strcmp(type, arguments[i])) return NO;
    }
    return YES;
}

static inline BOOL NTIReelInstallHooks(Class cls, const NTIReelHook *hooks, size_t count) {
    if (!cls) return NO;
    for (size_t i = 0; i < count; i++) {
        const NTIReelHook *hook = &hooks[i];
        if (!NTIReelMethodMatches(class_getInstanceMethod(cls, sel_registerName(hook->selector)),
                                 hook->returnType, hook->argumentCount, hook->argumentTypes)) return NO;
    }
    for (size_t i = 0; i < count; i++) {
        const NTIReelHook *hook = &hooks[i];
        SEL selector = sel_registerName(hook->selector);
        Method method = class_getInstanceMethod(cls, selector);
        if (hook->original) *hook->original = method_getImplementation(method);
        class_replaceMethod(cls, selector, hook->replacement, method_getTypeEncoding(method));
    }
    return YES;
}
