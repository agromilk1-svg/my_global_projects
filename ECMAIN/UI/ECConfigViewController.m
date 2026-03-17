//
//  ECConfigViewController.m
//  ECMAIN
//
//  Advanced Spoofing Configuration Interface Implementation
//

#import "ECConfigViewController.h"
#import "../Data/ECDeviceDatabase.h"
#import "../Dylib/ECDeviceSpoofConfig.h" // For keys and paths

@interface ECConfigViewController () <UIPickerViewDelegate,
                                      UIPickerViewDataSource>

@property(nonatomic, strong) UIPickerView *devicePicker;
@property(nonatomic, strong) UIPickerView *versionPicker;
@property(nonatomic, strong) UIPickerView *carrierPicker;

@property(nonatomic, strong) NSArray<ECDeviceModel *> *models;
@property(nonatomic, strong) NSArray<ECSystemVersion *> *versions;
@property(nonatomic, strong) NSArray<ECCarrierInfo *> *carriers;

@property(nonatomic, strong) ECDeviceModel *selectedModel;
@property(nonatomic, strong) ECSystemVersion *selectedVersion;
@property(nonatomic, strong) ECCarrierInfo *selectedCarrier;

@property(nonatomic, strong) UITextView *previewView;
@property(nonatomic, strong) UIButton *generateButton;
@property(nonatomic, strong) UIButton *saveButton;
@property(nonatomic, strong) UITextField *adminTextField;

@end

@implementation ECConfigViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor whiteColor];
  self.title = @"高级伪装配置 v2.0";

  // Load Data
  self.models = [[ECDeviceDatabase shared] alliPhoneModels];
  self.carriers = [[ECDeviceDatabase shared] supportedCarriers];

  // Default Select
  self.selectedModel = self.models.firstObject;
  [self updateVersions];
  self.selectedCarrier = self.carriers.firstObject;

  [self setupUI];
  [self loadCurrentConfig];
}

- (void)loadCurrentConfig {
    NSString *path = EC_SPOOF_GLOBAL_CONFIG_PATH;
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:path];
    if (config && config[@"admin_username"]) {
        self.adminTextField.text = config[@"admin_username"];
    }
}

- (void)updateVersions {
  self.versions =
      [[ECDeviceDatabase shared] versionsForModel:self.selectedModel];
  if (self.versions.count > 0) {
    self.selectedVersion = self.versions.firstObject;
  } else {
    self.selectedVersion = nil;
  }
  [self.versionPicker reloadAllComponents];
}

- (void)setupUI {
  CGFloat y = 100;
  CGFloat width = self.view.bounds.size.width;
  CGFloat padding = 20;
  CGFloat labelH = 20;
  CGFloat pickerH = 100;

  // 1. Model Picker
  UILabel *l1 =
      [[UILabel alloc] initWithFrame:CGRectMake(padding, y, width, labelH)];
  l1.text = @"1. 选择机型 (Device Model)";
  [self.view addSubview:l1];
  y += labelH;

  self.devicePicker =
      [[UIPickerView alloc] initWithFrame:CGRectMake(0, y, width, pickerH)];
  self.devicePicker.delegate = self;
  self.devicePicker.dataSource = self;
  self.devicePicker.tag = 1;
  [self.view addSubview:self.devicePicker];
  y += pickerH;

  // 2. Version Picker
  UILabel *l2 =
      [[UILabel alloc] initWithFrame:CGRectMake(padding, y, width, labelH)];
  l2.text = @"2. 选择系统 (iOS Version)";
  [self.view addSubview:l2];
  y += labelH;

  self.versionPicker =
      [[UIPickerView alloc] initWithFrame:CGRectMake(0, y, width, pickerH)];
  self.versionPicker.delegate = self;
  self.versionPicker.dataSource = self;
  self.versionPicker.tag = 2;
  [self.view addSubview:self.versionPicker];
  y += pickerH;

  // 3. Carrier Picker
  UILabel *l3 =
      [[UILabel alloc] initWithFrame:CGRectMake(padding, y, width, labelH)];
  l3.text = @"3. 选择地区/运营商 (Region/Carrier)";
  [self.view addSubview:l3];
  y += labelH;

  self.carrierPicker =
      [[UIPickerView alloc] initWithFrame:CGRectMake(0, y, width, pickerH)];
  self.carrierPicker.delegate = self;
  self.carrierPicker.dataSource = self;
  self.carrierPicker.tag = 3;
  [self.view addSubview:self.carrierPicker];
  y += pickerH + 10;

  // 4. Admin Account
  UILabel *l4 = [[UILabel alloc] initWithFrame:CGRectMake(padding, y, width, labelH)];
  l4.text = @"4. 所属管理员账号 (Admin Account)";
  [self.view addSubview:l4];
  y += labelH + 5;

  self.adminTextField = [[UITextField alloc] initWithFrame:CGRectMake(padding, y, width - 2*padding, 36)];
  self.adminTextField.borderStyle = UITextBorderStyleRoundedRect;
  self.adminTextField.placeholder = @"输入控制中心管理员用户名";
  self.adminTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
  [self.view addSubview:self.adminTextField];
  y += 46;

  // Buttons
  CGFloat btnW = (width - 3 * padding) / 2;

  self.generateButton = [UIButton buttonWithType:UIButtonTypeSystem];
  self.generateButton.frame = CGRectMake(padding, y, btnW, 44);
  [self.generateButton setTitle:@"🔄 生成预览" forState:UIControlStateNormal];
  self.generateButton.backgroundColor = [UIColor systemBlueColor];
  [self.generateButton setTitleColor:[UIColor whiteColor]
                            forState:UIControlStateNormal];
  self.generateButton.layer.cornerRadius = 8;
  [self.generateButton addTarget:self
                          action:@selector(generateTapped)
                forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.generateButton];

  self.saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
  self.saveButton.frame = CGRectMake(padding * 2 + btnW, y, btnW, 44);
  [self.saveButton setTitle:@"💾 保存配置" forState:UIControlStateNormal];
  self.saveButton.backgroundColor = [UIColor systemGreenColor];
  [self.saveButton setTitleColor:[UIColor whiteColor]
                        forState:UIControlStateNormal];
  self.saveButton.layer.cornerRadius = 8;
  [self.saveButton addTarget:self
                      action:@selector(saveTapped)
            forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.saveButton];
  y += 50;

  // Preview
  self.previewView = [[UITextView alloc]
      initWithFrame:CGRectMake(padding, y, width - 2 * padding,
                               self.view.bounds.size.height - y - 20)];
  self.previewView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
  self.previewView.font = [UIFont fontWithName:@"Courier" size:12];
  self.previewView.editable = NO;
  self.previewView.layer.cornerRadius = 8;
  [self.view addSubview:self.previewView];

  // Initial Generate
  [self generateTapped];
}

#pragma mark - Picker Delegate

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
  return 1;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView
    numberOfRowsInComponent:(NSInteger)component {
  if (pickerView.tag == 1)
    return self.models.count;
  if (pickerView.tag == 2)
    return self.versions.count;
  if (pickerView.tag == 3)
    return self.carriers.count;
  return 0;
}

- (NSString *)pickerView:(UIPickerView *)pickerView
             titleForRow:(NSInteger)row
            forComponent:(NSInteger)component {
  if (pickerView.tag == 1)
    return self.models[row].displayName;
  if (pickerView.tag == 2)
    return
        [NSString stringWithFormat:@"iOS %@ (%@)", self.versions[row].osVersion,
                                   self.versions[row].buildVersion];
  if (pickerView.tag == 3)
    return
        [NSString stringWithFormat:@"%@ - %@", self.carriers[row].countryName,
                                   self.carriers[row].carrierName];
  return @"";
}

- (void)pickerView:(UIPickerView *)pickerView
      didSelectRow:(NSInteger)row
       inComponent:(NSInteger)component {
  if (pickerView.tag == 1) {
    self.selectedModel = self.models[row];
    [self updateVersions];
    // Versions changed, invalidating selection usually resets to top, ensure
    // consistency
  } else if (pickerView.tag == 2) {
    self.selectedVersion = self.versions[row];
  } else if (pickerView.tag == 3) {
    self.selectedCarrier = self.carriers[row];
  }

  [self generateTapped];
}

#pragma mark - Actions

- (void)generateTapped {
  if (!self.selectedModel || !self.selectedVersion || !self.selectedCarrier) {
    self.previewView.text = @"请先选择完整的参数。";
    return;
  }

  NSDictionary *config = [[ECDeviceDatabase shared]
      tim_generateConfigForModel:self.selectedModel
                         version:self.selectedVersion
                         carrier:self.selectedCarrier];

  NSError *error;
  NSData *jsonData =
      [NSJSONSerialization dataWithJSONObject:config
                                      options:NSJSONWritingPrettyPrinted
                                        error:&error];
  if (jsonData) {
    self.previewView.text =
        [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
  }
}

- (void)saveTapped {
  NSMutableDictionary *config = [[[ECDeviceDatabase shared]
      tim_generateConfigForModel:self.selectedModel
                         version:self.selectedVersion
                         carrier:self.selectedCarrier] mutableCopy];
                         
  if (self.adminTextField.text.length > 0) {
      config[@"admin_username"] = self.adminTextField.text;
  }

  NSString *path =
      EC_SPOOF_GLOBAL_CONFIG_PATH; // /var/mobile/Documents/ECSpoof/device.plist

  // Check writability - assuming we are running as User usually, but this path
  // is mobile writable
  BOOL success = [config writeToFile:path atomically:YES];

  if (success) {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"保存成功"
                         message:[NSString
                                     stringWithFormat:@"配置已写入:\n%@", path]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
  } else {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"保存失败"
                         message:@"无法写入文件，请检查权限 "
                                 @"(RootHelper/TrollStore) 或目录是否存在。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
  }
}

@end
