#import <Foundation/Foundation.h>

extern mach_msg_return_t SBReloadIconForIdentifier(mach_port_t machport,
                                                   const char *identifier);

// Interface for SBSHomeScreenService is defined in main.m locally
// @interface SBSHomeScreenService : NSObject
// - (void)reloadIcons;
// @end
