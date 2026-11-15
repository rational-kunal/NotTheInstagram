#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

static inline BOOL NTIIsInstagram(NSString *identifier) {
    return [identifier isEqualToString:@"com.burbn.instagram"] || [identifier hasPrefix:@"com.burbn.instagram."];
}

// Validate the full signature before replacing a method on its target class.
typedef struct {
    const char *selector;
    IMP replacement;
    IMP *original;
    const char *returnType;
    unsigned int argumentCount;
    const char *argumentTypes[6];
} NTIHook;

static inline BOOL NTIMethodMatches(Method method, const char *result,
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

static inline id NTIObjectValue(id object, SEL selector) {
    if (!NTIMethodMatches(class_getInstanceMethod(object_getClass(object), selector), @encode(id), 0, NULL)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static inline BOOL NTIBoolValueIs(id object, SEL selector, BOOL expected) {
    return NTIMethodMatches(class_getInstanceMethod(object_getClass(object), selector), @encode(BOOL), 0, NULL) &&
        ((BOOL (*)(id, SEL))objc_msgSend)(object, selector) == expected;
}

static inline BOOL NTIHooksMatch(Class cls, const NTIHook *hooks, size_t count) {
    if (!cls) return NO;
    for (size_t i = 0; i < count; i++) {
        const NTIHook *hook = &hooks[i];
        if (!NTIMethodMatches(class_getInstanceMethod(cls, sel_registerName(hook->selector)),
                              hook->returnType, hook->argumentCount, hook->argumentTypes)) return NO;
    }
    return YES;
}

static inline void NTIReplaceHooks(Class cls, const NTIHook *hooks, size_t count) {
    for (size_t i = 0; i < count; i++) {
        const NTIHook *hook = &hooks[i];
        SEL selector = sel_registerName(hook->selector);
        Method method = class_getInstanceMethod(cls, selector);
        if (hook->original) *hook->original = method_getImplementation(method);
        class_replaceMethod(cls, selector, hook->replacement, method_getTypeEncoding(method));
    }
}

static inline BOOL NTIInstallHooks(Class cls, const NTIHook *hooks, size_t count) {
    if (!NTIHooksMatch(cls, hooks, count)) return NO;
    NTIReplaceHooks(cls, hooks, count);
    return YES;
}
