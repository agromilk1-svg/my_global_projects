#import <Foundation/Foundation.h>

__attribute__((constructor))
static void empty_init() {
    NSLog(@"[EmptyDylib] Injected successfully, but doing nothing!");
}
