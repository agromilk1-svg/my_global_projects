//
//  ECQRScannerViewController.m
//  ECMAIN
//
//  QR Code Scanner using AVFoundation
//

#import "ECQRScannerViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

@interface ECQRScannerViewController () <AVCaptureMetadataOutputObjectsDelegate>
@property(nonatomic, strong) AVCaptureSession *captureSession;
@property(nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property(nonatomic, assign) BOOL isScanning;
@end

@implementation ECQRScannerViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor blackColor];
  self.navigationItem.title = @"扫描二维码";

  // Add close button
  self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                           target:self
                           action:@selector(dismissScanner)];

  [self setupCamera];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  if (self.captureSession && !self.captureSession.isRunning) {
    dispatch_async(
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          [self.captureSession startRunning];
        });
  }
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  if (self.captureSession && self.captureSession.isRunning) {
    [self.captureSession stopRunning];
  }
}

- (void)setupCamera {
  // Check camera permission
  AVAuthorizationStatus status =
      [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];

  if (status == AVAuthorizationStatusNotDetermined) {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                             completionHandler:^(BOOL granted) {
                               dispatch_async(dispatch_get_main_queue(), ^{
                                 if (granted) {
                                   [self initializeCamera];
                                 } else {
                                   [self showPermissionDeniedAlert];
                                 }
                               });
                             }];
  } else if (status == AVAuthorizationStatusAuthorized) {
    [self initializeCamera];
  } else {
    [self showPermissionDeniedAlert];
  }
}

- (void)initializeCamera {
  self.captureSession = [[AVCaptureSession alloc] init];

  AVCaptureDevice *device =
      [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  if (!device) {
    [self showAlert:@"错误" message:@"无法访问摄像头"];
    return;
  }

  NSError *error = nil;
  AVCaptureDeviceInput *input =
      [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
  if (error) {
    [self showAlert:@"错误" message:error.localizedDescription];
    return;
  }

  if ([self.captureSession canAddInput:input]) {
    [self.captureSession addInput:input];
  }

  AVCaptureMetadataOutput *output = [[AVCaptureMetadataOutput alloc] init];
  if ([self.captureSession canAddOutput:output]) {
    [self.captureSession addOutput:output];
    [output setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
    [output setMetadataObjectTypes:@[ AVMetadataObjectTypeQRCode ]];
  }

  // Preview layer
  self.previewLayer =
      [AVCaptureVideoPreviewLayer layerWithSession:self.captureSession];
  self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
  self.previewLayer.frame = self.view.bounds;
  [self.view.layer insertSublayer:self.previewLayer atIndex:0];

  // Add scan frame overlay
  [self addScanFrameOverlay];

  // Start session
  self.isScanning = YES;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                 ^{
                   [self.captureSession startRunning];
                 });
}

- (void)addScanFrameOverlay {
  CGFloat size = 250;
  CGFloat x = (self.view.bounds.size.width - size) / 2;
  CGFloat y = (self.view.bounds.size.height - size) / 2 - 50;

  // Semi-transparent overlay
  UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
  overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];

  // Cut out the scan area
  UIBezierPath *path = [UIBezierPath bezierPathWithRect:overlay.bounds];
  UIBezierPath *scanPath =
      [UIBezierPath bezierPathWithRoundedRect:CGRectMake(x, y, size, size)
                                 cornerRadius:12];
  [path appendPath:scanPath];
  path.usesEvenOddFillRule = YES;

  CAShapeLayer *maskLayer = [CAShapeLayer layer];
  maskLayer.path = path.CGPath;
  maskLayer.fillRule = kCAFillRuleEvenOdd;
  overlay.layer.mask = maskLayer;

  [self.view addSubview:overlay];

  // Scan frame border
  UIView *scanFrame =
      [[UIView alloc] initWithFrame:CGRectMake(x, y, size, size)];
  scanFrame.layer.borderColor = [UIColor systemGreenColor].CGColor;
  scanFrame.layer.borderWidth = 3;
  scanFrame.layer.cornerRadius = 12;
  [self.view addSubview:scanFrame];

  // Hint label
  UILabel *hintLabel = [[UILabel alloc] init];
  hintLabel.text = @"将二维码放入框内扫描";
  hintLabel.textColor = [UIColor whiteColor];
  hintLabel.font = [UIFont systemFontOfSize:16];
  hintLabel.textAlignment = NSTextAlignmentCenter;
  [hintLabel sizeToFit];
  hintLabel.center =
      CGPointMake(self.view.bounds.size.width / 2, y + size + 40);
  [self.view addSubview:hintLabel];
}

#pragma mark - AVCaptureMetadataOutputObjectsDelegate

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputMetadataObjects:
        (NSArray<__kindof AVMetadataObject *> *)metadataObjects
              fromConnection:(AVCaptureConnection *)connection {

  if (!self.isScanning)
    return;

  for (AVMetadataObject *metadata in metadataObjects) {
    if ([metadata isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) {
      AVMetadataMachineReadableCodeObject *code =
          (AVMetadataMachineReadableCodeObject *)metadata;
      NSString *value = code.stringValue;

      if (value && value.length > 0) {
        self.isScanning = NO;

        // Haptic feedback
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);

        // Stop session
        [self.captureSession stopRunning];

        // Notify delegate
        if ([self.delegate respondsToSelector:@selector(didScanQRCode:)]) {
          [self.delegate didScanQRCode:value];
        }

        // Dismiss
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
      }
    }
  }
}

#pragma mark - Helpers

- (void)dismissScanner {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)showPermissionDeniedAlert {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"需要相机权限"
                       message:@"请在设置中允许访问相机以扫描二维码"
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:^(UIAlertAction *action) {
                                            [self dismissScanner];
                                          }]];
  [alert
      addAction:
          [UIAlertAction
              actionWithTitle:@"设置"
                        style:UIAlertActionStyleDefault
                      handler:^(UIAlertAction *action) {
                        [[UIApplication sharedApplication]
                                      openURL:
                                          [NSURL
                                              URLWithString:
                                                  UIApplicationOpenSettingsURLString]
                                      options:@{}
                            completionHandler:nil];
                      }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:title
                                          message:message
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

@end
