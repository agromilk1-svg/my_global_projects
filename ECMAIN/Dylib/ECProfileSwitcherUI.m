//
//  ECProfileSwitcherUI.m
//  ECProfileSpoof (方案 C)
//
//  悬浮球 + Profile 切换列表 UI
//  使用独立 UIWindow 层级，不影响 TikTok 原生 UI
//

#import "ECProfileSwitcherUI.h"
#import "ECProfileManager.h"

// ============================================================================
#pragma mark - 悬浮球 View
// ============================================================================

@interface ECFloatingBallView : UIView
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, copy) void (^onTap)(void);
@end

@implementation ECFloatingBallView

- (instancetype)init {
  self = [super initWithFrame:CGRectMake(0, 0, 44, 44)];
  if (self) {
    self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.75];
    self.layer.cornerRadius = 22;
    self.layer.borderWidth = 1.5;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.3].CGColor;
    self.clipsToBounds = YES;

    _label = [[UILabel alloc] initWithFrame:self.bounds];
    _label.text = @"P";
    _label.textColor = [UIColor whiteColor];
    _label.textAlignment = NSTextAlignmentCenter;
    _label.font = [UIFont boldSystemFontOfSize:18];
    [self addSubview:_label];

    // 拖拽手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:pan];

    // 点击手势
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleTap:)];
    [self addGestureRecognizer:tap];
  }
  return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
  UIView *superview = self.superview;
  if (!superview) return;
  CGPoint translation = [gesture translationInView:superview];
  self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
  [gesture setTranslation:CGPointZero inView:superview];

  // 结束时吸附到屏幕边缘
  if (gesture.state == UIGestureRecognizerStateEnded) {
    CGFloat screenW = superview.bounds.size.width;
    CGFloat targetX = (self.center.x < screenW / 2) ? 28 : screenW - 28;
    [UIView animateWithDuration:0.25 animations:^{
      self.center = CGPointMake(targetX, self.center.y);
    }];
  }
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {
  if (self.onTap) self.onTap();
}

- (void)updateLabel:(NSString *)text {
  self.label.text = text;
}

@end

// ============================================================================
#pragma mark - Profile 列表 ViewController
// ============================================================================

@interface ECProfileListController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<ECProfileInfo *> *profiles;
@property (nonatomic, copy) NSString *activeId;
@end

@implementation ECProfileListController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];

  // 卡片容器
  CGFloat cardH = 360;
  CGFloat cardW = MIN(self.view.bounds.size.width - 40, 340);
  UIView *card = [[UIView alloc] initWithFrame:CGRectMake(
      (self.view.bounds.size.width - cardW) / 2,
      (self.view.bounds.size.height - cardH) / 2, cardW, cardH)];
  card.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.14 alpha:1.0];
  card.layer.cornerRadius = 16;
  card.clipsToBounds = YES;
  [self.view addSubview:card];

  // 标题
  UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, cardW - 80, 30)];
  title.text = @"🔀 切换账号";
  title.textColor = [UIColor whiteColor];
  title.font = [UIFont boldSystemFontOfSize:18];
  [card addSubview:title];

  // 关闭按钮
  UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  closeBtn.frame = CGRectMake(cardW - 60, 8, 50, 36);
  [closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
  [closeBtn setTitleColor:[UIColor colorWithRed:0.4 green:0.6 blue:1.0 alpha:1.0]
                 forState:UIControlStateNormal];
  [closeBtn addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
  [card addSubview:closeBtn];

  // 表格
  _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 48, cardW, cardH - 100)
                                            style:UITableViewStylePlain];
  _tableView.backgroundColor = [UIColor clearColor];
  _tableView.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.1];
  _tableView.dataSource = self;
  _tableView.delegate = self;
  [_tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];
  [card addSubview:_tableView];

  // 新建按钮
  UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  addBtn.frame = CGRectMake(16, cardH - 48, cardW - 32, 40);
  addBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:1.0 alpha:1.0];
  addBtn.layer.cornerRadius = 8;
  [addBtn setTitle:@"＋ 新建 Profile" forState:UIControlStateNormal];
  [addBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  [addBtn addTarget:self action:@selector(createNewProfile) forControlEvents:UIControlEventTouchUpInside];
  [card addSubview:addBtn];

  // 加载数据
  [self reloadData];

  // 点击背景关闭
  UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc]
      initWithTarget:self action:@selector(dismiss)];
  bgTap.cancelsTouchesInView = NO;
  [self.view addGestureRecognizer:bgTap];
}

- (void)reloadData {
  self.profiles = [[ECProfileManager shared] allProfiles];
  self.activeId = [[ECProfileManager shared] activeProfileId];
  [self.tableView reloadData];
}

- (void)dismiss {
  [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return self.profiles.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
  ECProfileInfo *p = self.profiles[indexPath.row];

  BOOL isActive = [p.profileId isEqualToString:self.activeId];
  cell.textLabel.text = [NSString stringWithFormat:@"%@ %@",
      isActive ? @"✅" : @"⚪️", p.name];
  cell.textLabel.textColor = [UIColor whiteColor];
  cell.backgroundColor = [UIColor clearColor];
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  ECProfileInfo *p = self.profiles[indexPath.row];
  if ([p.profileId isEqualToString:self.activeId]) return; // 已是当前 Profile

  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"切换账号"
                       message:[NSString stringWithFormat:@"切换到「%@」需要重启 TikTok，确定吗？", p.name]
                preferredStyle:UIAlertControllerStyleAlert];

  [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:@"切换并重启" style:UIAlertActionStyleDestructive
      handler:^(UIAlertAction *action) {
        [[ECProfileManager shared] switchToProfile:p.profileId];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
          exit(0);
        });
      }]];

  [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
  ECProfileInfo *p = self.profiles[indexPath.row];
  return ![p.profileId isEqualToString:@"0"]; // 默认 Profile 不可删除
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style
    forRowAtIndexPath:(NSIndexPath *)indexPath {
  if (style == UITableViewCellEditingStyleDelete) {
    ECProfileInfo *p = self.profiles[indexPath.row];
    [[ECProfileManager shared] deleteProfile:p.profileId];
    [self reloadData];
  }
}

#pragma mark - 新建 Profile

- (void)createNewProfile {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"新建 Profile"
                       message:@"输入名称"
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
    tf.placeholder = @"例如：小号 1";
  }];
  [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault
      handler:^(UIAlertAction *action) {
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0) name = @"新账号";
        [[ECProfileManager shared] createNewProfileWithName:name];
        [self reloadData];
      }]];
  [self presentViewController:alert animated:YES completion:nil];
}

@end

// ============================================================================
#pragma mark - ECProfileSwitcherUI 安装
// ============================================================================

@implementation ECProfileSwitcherUI

+ (void)install {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    // 创建独立 Window（不影响 TikTok 原有 UI）
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
      if ([s isKindOfClass:[UIWindowScene class]]) {
        scene = (UIWindowScene *)s;
        break;
      }
    }
    if (!scene) {
      NSLog(@"[ECProfileC] ⚠️ 未找到 WindowScene，延迟安装悬浮球");
      return;
    }

    UIWindow *floatingWindow = [[UIWindow alloc] initWithWindowScene:scene];
    floatingWindow.frame = CGRectMake(0, 0, 44, 44);
    floatingWindow.windowLevel = UIWindowLevelAlert + 100;
    floatingWindow.backgroundColor = [UIColor clearColor];
    floatingWindow.hidden = NO;
    floatingWindow.userInteractionEnabled = YES;

    // 设置 rootViewController（必须，否则 window 不响应触摸）
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    floatingWindow.rootViewController = vc;

    // 添加悬浮球
    ECFloatingBallView *ball = [[ECFloatingBallView alloc] init];
    CGFloat screenW = UIScreen.mainScreen.bounds.size.width;
    ball.center = CGPointMake(screenW - 28, 200);

    // 显示当前 Profile ID
    NSString *pid = [[ECProfileManager shared] activeProfileId];
    [ball updateLabel:[NSString stringWithFormat:@"P%@", pid]];

    ball.onTap = ^{
      ECProfileListController *list = [[ECProfileListController alloc] init];
      list.modalPresentationStyle = UIModalPresentationOverFullScreen;
      list.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;

      UIViewController *topVC = nil;
      for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
          for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w.isKeyWindow) {
              topVC = w.rootViewController;
              break;
            }
          }
          if (topVC) break;
        }
      }
      while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
      }
      [topVC presentViewController:list animated:YES completion:nil];
    };

    [vc.view addSubview:ball];

    // 让 window 仅覆盖悬浮球区域，不阻挡其他触摸
    floatingWindow.frame = CGRectMake(screenW - 56, 178, 56, 56);

    NSLog(@"[ECProfileC] ✅ 悬浮球已安装，当前 Profile: %@", pid);
  });
}

@end
