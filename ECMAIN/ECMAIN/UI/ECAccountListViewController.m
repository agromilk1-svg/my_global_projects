//
//  ECAccountListViewController.m
//  ECMAIN
//
//  账号管理列表
//

#import "ECAccountListViewController.h"
#import "../Core/ECPersistentConfig.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>

@interface ECAccountListViewController ()

@property (nonatomic, strong) NSArray *accounts;
@property (nonatomic, strong) NSArray *sections; // [@"TK", @"FB"]
@property (nonatomic, strong) NSDictionary *groupedAccounts;

@end

@implementation ECAccountListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"本端账号";
    
    if (@available(iOS 13.0, *)) {
        self.view.backgroundColor = [UIColor systemBackgroundColor];
    }
    
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 80;
    
    // Pull to refresh
    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(fetchAccountsFromServer) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refreshControl;
    
    // 顶部按钮：下载与上传
    UIBarButtonItem *downloadBtn = [[UIBarButtonItem alloc] initWithTitle:@"下载" style:UIBarButtonItemStylePlain target:self action:@selector(fetchAccountsFromServer)];
    UIBarButtonItem *uploadBtn = [[UIBarButtonItem alloc] initWithTitle:@"上传" style:UIBarButtonItemStylePlain target:self action:@selector(postAccountsToServer)];
    self.navigationItem.rightBarButtonItems = @[downloadBtn, uploadBtn];
    
    [self loadAccountsFromCache];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadAccountsFromCache];
}

- (NSString *)getDeviceUDID {
    NSString *udid = nil;
    void *lib = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (lib) {
        CFTypeRef (*_MGCopyAnswer)(CFStringRef) = dlsym(lib, "MGCopyAnswer");
        if (_MGCopyAnswer) {
            CFStringRef uniqueId = (CFStringRef)_MGCopyAnswer(CFSTR("SerialNumber"));
            if (uniqueId) {
                udid = [NSString stringWithString:(__bridge NSString *)uniqueId];
                CFRelease(uniqueId);
            }
        }
        dlclose(lib);
    }
    if (!udid) {
        udid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    }
    return udid;
}

- (void)fetchAccountsFromServer {
    NSString *serverUrl = [ECPersistentConfig stringForKey:@"EC_SERVER_URL"];
    if (!serverUrl || serverUrl.length == 0) {
        [self.refreshControl endRefreshing];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"未配置服务器" message:@"请先在控制面板中配置主控服务器地址。" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
        return;
    }
    
    NSString *udid = [self getDeviceUDID];
    NSString *apiUrl = [NSString stringWithFormat:@"%@/api/devices/%@/accounts", serverUrl, udid];
    NSURL *url = [NSURL URLWithString:apiUrl];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 15.0;
    
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.refreshControl endRefreshing];
            if (!error && data) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([json isKindOfClass:[NSDictionary class]] && [json[@"status"] isEqualToString:@"ok"]) {
                    NSArray *fetchedAccounts = json[@"data"];
                    
                    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
                    NSData *cacheData = [NSJSONSerialization dataWithJSONObject:fetchedAccounts options:0 error:nil];
                    NSString *cacheString = [[NSString alloc] initWithData:cacheData encoding:NSUTF8StringEncoding];
                    [defaults setObject:cacheString forKey:@"EC_ACCOUNTS"];
                    [defaults synchronize];
                    
                    [self loadAccountsFromCache];
                    
                    // 手动点击下载时给予回馈
                    if (!self.refreshControl.isRefreshing) {
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"下载成功" message:[NSString stringWithFormat:@"已从服务器拉取 %lu 个账号", (unsigned long)fetchedAccounts.count] preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                        [self presentViewController:alert animated:YES completion:nil];
                    }
                }
            } else {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"获取失败" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            }
        });
    }] resume];
}

- (void)postAccountsToServer {
    NSString *serverUrl = [ECPersistentConfig stringForKey:@"EC_SERVER_URL"];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
    NSString *json = [defaults stringForKey:@"EC_ACCOUNTS"] ?: @"[]";
    NSArray *accountsArr = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    
    if (!serverUrl || serverUrl.length == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"未配置服务器" message:@"请先在控制面板中配置主控服务器地址。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    if (![accountsArr isKindOfClass:[NSArray class]] || accountsArr.count == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无数据" message:@"本地暂无账号数据可上传。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSString *udid = [self getDeviceUDID];
    NSString *apiUrl = [NSString stringWithFormat:@"%@/api/devices/%@/accounts", serverUrl, udid];
    NSURL *url = [NSURL URLWithString:apiUrl];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:accountsArr options:0 error:nil];
    request.timeoutInterval = 15.0;
    
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!error) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"上传成功" message:@"账号统计信息已成功提交至服务器。" preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            } else {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"上传失败" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            }
        });
    }] resume];
}

- (void)loadAccountsFromCache {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
    NSString *json = [defaults stringForKey:@"EC_ACCOUNTS"] ?: @"[]";
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *accounts = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![accounts isKindOfClass:[NSArray class]]) {
        accounts = @[];
    }
    self.accounts = accounts;
    
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];
    for (NSDictionary *acc in self.accounts) {
        NSString *type = acc[@"account_type"] ?: @"OTHER";
        NSMutableArray *arr = groups[type];
        if (!arr) {
            arr = [NSMutableArray array];
            groups[type] = arr;
        }
        [arr addObject:acc];
    }
    self.groupedAccounts = groups;
    self.sections = [[groups allKeys] sortedArrayUsingSelector:@selector(compare:)];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSString *type = self.sections[section];
    NSArray *items = self.groupedAccounts[type];
    return items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *type = self.sections[section];
    NSArray *items = self.groupedAccounts[type];
    return [NSString stringWithFormat:@"%@ 账号 (%lu)", type, (unsigned long)items.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *CellIdentifier = @"AccountCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellIdentifier];
    }
    
    NSString *type = self.sections[indexPath.section];
    NSArray *items = self.groupedAccounts[type];
    NSDictionary *acc = items[indexPath.row];
    
    BOOL isPrimary = [acc[@"is_primary"] boolValue];
    NSString *title = [NSString stringWithFormat:@"%@%@", isPrimary ? @"⭐ " : @"", acc[@"account"] ?: @"---"];
    cell.textLabel.text = title;
    cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
    
    BOOL isWindow = [acc[@"is_window_opened"] boolValue];
    BOOL isSale = [acc[@"is_for_sale"] boolValue];
    BOOL isFollowing = [acc[@"is_following"] boolValue];
    BOOL isFarming = [acc[@"is_farming"] boolValue];
    NSNumber *fans = acc[@"fans_count"] ?: @0;
    NSNumber *followingCount = acc[@"following_count"] ?: @0;
    NSNumber *likes = acc[@"likes_count"] ?: @0;
    
    NSMutableArray *tags = [NSMutableArray array];
    if (isWindow) [tags addObject:@"[开窗]"];
    if (isSale) [tags addObject:@"[已售]"];
    if (isFollowing) [tags addObject:@"[关注]"];
    if (isFarming) [tags addObject:@"[养号]"];
    
    NSString *tagString = [tags componentsJoinedByString:@" "];
    
    NSString *addTime = acc[@"add_time"] ?: @"---";
    NSString *updateTime = acc[@"update_time"] ?: @"---";
    NSString *timeStr = [NSString stringWithFormat:@"\n🕒 添加: %@ | ↻ 更新: %@", addTime, updateTime];
    
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"📊 关注: %@ | 粉丝: %@ | 点赞: %@ | %@ %@%@", 
                                followingCount, fans, likes, acc[@"country"] ?: @"", tagString, timeStr];
    cell.detailTextLabel.textColor = [UIColor systemGrayColor];
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

@end
