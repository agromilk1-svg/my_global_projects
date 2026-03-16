
#import "ECFileViewerViewController.h"
#import "../../TrollStoreCore/TSUtil.h"

extern int spawnRoot(NSString *path, NSArray *args, NSString **stdOut,
                     NSString **stdErr);
extern NSString *rootHelperPath(void);

@interface ECFileViewerViewController ()
@property(nonatomic, strong) NSString *filePath;
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, assign) BOOL isEditing;
@property(nonatomic, strong) NSString *originalContent;
@end

@implementation ECFileViewerViewController

- (instancetype)initWithPath:(NSString *)path {
  if (self = [super init]) {
    _filePath = path;
    self.title = [path lastPathComponent];
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor systemBackgroundColor];

  self.textView = [[UITextView alloc] initWithFrame:self.view.bounds];
  self.textView.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.textView.font = [UIFont systemFontOfSize:14];
  self.textView.editable = NO;
  [self.view addSubview:self.textView];

  [self loadContent];
  [self setupNavigationItems];

  // 监听键盘通知以调整 TextView Inset
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(keyboardWillShow:)
             name:UIKeyboardWillShowNotification
           object:nil];
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(keyboardWillHide:)
             name:UIKeyboardWillHideNotification
           object:nil];
}

- (void)setupNavigationItems {
  // 清除现有的按钮，防止冲突
  self.navigationItem.rightBarButtonItems = nil;
  self.navigationItem.leftBarButtonItem = nil;
  self.navigationItem.rightBarButtonItem = nil;

  if (self.isEditing) {
    // 编辑模式：右边显示 [保存]，左边显示 [取消]
    UIBarButtonItem *saveItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(saveTapped)];

    self.navigationItem.rightBarButtonItem = saveItem;

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(cancelTapped)];
  } else {
    // 查看模式：右边显示 [编辑] [分享]
    UIBarButtonItem *editItem =
        [[UIBarButtonItem alloc] initWithTitle:@"编辑"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(editTapped)];

    UIBarButtonItem *shareItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                             target:self
                             action:@selector(shareTapped)];

    self.navigationItem.rightBarButtonItems = @[ editItem, shareItem ];
  }
}

- (void)loadContent {
  NSError *error = nil;
  NSString *content = nil;

  // 1. 尝试作为 UTF-8 读取
  content = [NSString stringWithContentsOfFile:self.filePath
                                      encoding:NSUTF8StringEncoding
                                         error:NULL];

  // 2. 如果失败，尝试作为 ASCII 读取 (可能包含非 UTF-8 字符)
  if (!content) {
    content = [NSString stringWithContentsOfFile:self.filePath
                                        encoding:NSASCIIStringEncoding
                                           error:NULL];
  }

  // 3. 如果还是失败，且扩展名为 plist，尝试转换为 XML
  if (!content ||
      [self.filePath.pathExtension.lowercaseString isEqualToString:@"plist"]) {
    NSData *data = [NSData dataWithContentsOfFile:self.filePath];
    if (data) {
      id plist = [NSPropertyListSerialization
          propertyListWithData:data
                       options:NSPropertyListMutableContainersAndLeaves
                        format:NULL
                         error:NULL];
      if (plist) {
        NSData *xmlData = [NSPropertyListSerialization
            dataWithPropertyList:plist
                          format:NSPropertyListXMLFormat_v1_0
                         options:0
                           error:NULL];
        if (xmlData) {
          content = [[NSString alloc] initWithData:xmlData
                                          encoding:NSUTF8StringEncoding];
        }
      }
    }
  }

  // 4. 如果所有尝试都失败，报错但允许编辑 (可能就是一个空文件或无法识别的文件)
  if (!content) {
    if (!error) {
      error = [NSError
          errorWithDomain:@"ECFileViewer"
                     code:-1
                 userInfo:@{
                   NSLocalizedDescriptionKey :
                       @"无法以文本或 Plist 格式读取文件 (可能是二进制文件)"
                 }];
    }
    self.textView.text = [NSString
        stringWithFormat:
            @"无法读取文件内容:\n%@\n\n您可以尝试直接编辑并覆盖原文件。",
            error.localizedDescription];
    self.textView.textColor = [UIColor redColor];
  } else {
    self.textView.text = content;
    self.originalContent = content; // Keep original for revert
    self.textView.textColor = [UIColor labelColor];
  }

  // 无论成败，总是确保导航栏按钮存在 (允许创建/覆盖)
  [self setupNavigationItems];
}

- (void)editTapped {
  self.isEditing = YES;
  self.textView.editable = YES;
  [self.textView becomeFirstResponder];
  [self setupNavigationItems];
}

- (void)saveTapped {
  NSError *error = nil;
  NSString *contentToSave = self.textView.text;

  // 如果是 Plist 文件，尝试验证 XML 格式是否合法（可选，防止保存坏文件）
  if ([self.filePath.pathExtension.lowercaseString isEqualToString:@"plist"]) {
    NSData *data = [contentToSave dataUsingEncoding:NSUTF8StringEncoding];
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:0
                                                          format:NULL
                                                           error:&error];
    if (error) {
      UIAlertController *alert = [UIAlertController
          alertControllerWithTitle:@"格式错误"
                           message:[NSString
                                       stringWithFormat:
                                           @"Plist 格式无效，无法保存:\n%@",
                                           error.localizedDescription]
                    preferredStyle:UIAlertControllerStyleAlert];
      [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                                style:UIAlertActionStyleDefault
                                              handler:nil]];
      [self presentViewController:alert animated:YES completion:nil];
      return;
    }
  }

  // 尝试标准写入
  BOOL success = [contentToSave writeToFile:self.filePath
                                 atomically:YES
                                   encoding:NSUTF8StringEncoding
                                      error:&error];

  // 如果标准写入失败，尝试使用 RootHelper (trollstorehelper)
  if (!success) {
    NSLog(@"[ECFileViewer] Standard write failed: %@. Trying RootHelper...",
          error.localizedDescription);

    // 1. 写入临时文件
    NSString *tempFileName =
        [NSString stringWithFormat:@"%@_%@", [NSUUID UUID].UUIDString,
                                   [self.filePath lastPathComponent]];
    NSString *tempPath =
        [NSTemporaryDirectory() stringByAppendingPathComponent:tempFileName];

    // CRITICAL FIX: Reset error to nil before attempting second write!
    // Otherwise, 'if (error)' below will be true due to the first failure.
    error = nil;

    [contentToSave writeToFile:tempPath
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:&error];

    if (error) {
      NSLog(@"[ECFileViewer] Failed to write to temp file: %@", error);
    } else {
      // 2. 使用 trollstorehelper copy-file 覆盖目标文件
      // copy-file 会先删除目标文件再复制
      // copy-file usage: copy-file <src> <dst>
      NSArray *args = @[ @"copy-file", tempPath, self.filePath ];
      NSString *stdOut = nil;
      NSString *stdErr = nil;
      int ret = spawnRoot(rootHelperPath(), args, &stdOut, &stdErr);

      if (ret == 0) {
        success = YES;
        error = nil; // Clear error
        NSLog(@"[ECFileViewer] RootHelper save successful!");

        // 3. 修正权限 (644)
        spawnRoot(rootHelperPath(), @[ @"chmod-file", @"644", self.filePath ],
                  nil, nil);
      } else {
        NSLog(@"[ECFileViewer] RootHelper failed (ret=%d): %@ / %@", ret,
              stdOut, stdErr);
        // 更新错误信息
        NSString *debugInfo = [NSString
            stringWithFormat:@"Helper: %@\nRet: %d\nStdout: %@\nStderr: %@",
                             rootHelperPath(), ret, stdOut, stdErr];
        error = [NSError
            errorWithDomain:@"ECFileViewer"
                       code:ret
                   userInfo:@{
                     NSLocalizedDescriptionKey : [NSString
                         stringWithFormat:@"RootHelper Failed:\n%@", debugInfo]
                   }];
      }

      // 清理临时文件
      [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
    }
  }

  if (error) {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"保存失败"
                         message:error.localizedDescription
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
                         actionWithTitle:@"Copy Error"
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *_Nonnull action) {
                                   UIPasteboard.generalPasteboard.string =
                                       error.localizedDescription;
                                 }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
  } else {
    self.originalContent = self.textView.text;
    self.isEditing = NO;
    self.textView.editable = NO;
    [self.textView resignFirstResponder];
    [self setupNavigationItems];

    // 简单的成功提示
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"成功"
                         message:@"文件已保存"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
  }
}

- (void)cancelTapped {
  self.textView.text = self.originalContent;
  self.isEditing = NO;
  self.textView.editable = NO;
  [self.textView resignFirstResponder];
  [self setupNavigationItems];
}

- (void)shareTapped {
  NSURL *url = [NSURL fileURLWithPath:self.filePath];
  UIActivityViewController *activityVC =
      [[UIActivityViewController alloc] initWithActivityItems:@[ url ]
                                        applicationActivities:nil];
  [self presentViewController:activityVC animated:YES completion:nil];
}

#pragma mark - Keyboard Handling

- (void)keyboardWillShow:(NSNotification *)notification {
  NSDictionary *info = [notification userInfo];
  CGSize kbSize =
      [[info objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue].size;
  UIEdgeInsets contentInsets = UIEdgeInsetsMake(0.0, 0.0, kbSize.height, 0.0);
  self.textView.contentInset = contentInsets;
  self.textView.scrollIndicatorInsets = contentInsets;
}

- (void)keyboardWillHide:(NSNotification *)notification {
  UIEdgeInsets contentInsets = UIEdgeInsetsZero;
  self.textView.contentInset = contentInsets;
  self.textView.scrollIndicatorInsets = contentInsets;
}

@end
