//
//  ECQRScannerViewController.h
//  ECMAIN
//
//  QR Code Scanner for Proxy Configuration
//

#import <UIKit/UIKit.h>

@protocol ECQRScannerDelegate <NSObject>
- (void)didScanQRCode:(NSString *)code;
@end

@interface ECQRScannerViewController : UIViewController
@property(nonatomic, weak) id<ECQRScannerDelegate> delegate;
@end
