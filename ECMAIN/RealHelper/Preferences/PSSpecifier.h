#import <Foundation/Foundation.h>

@interface PSSpecifier : NSObject
@property(retain, nonatomic) NSString *name;
@property(retain, nonatomic) NSString *identifier;
@property(nonatomic) SEL buttonAction;
+ (instancetype)emptyGroupSpecifier;
+ (instancetype)preferenceSpecifierNamed:(NSString *)name
                                  target:(id)target
                                     set:(SEL)set
                                     get:(SEL)get
                                  detail:(Class)detail
                                    cell:(long)cell
                                    edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
@end
