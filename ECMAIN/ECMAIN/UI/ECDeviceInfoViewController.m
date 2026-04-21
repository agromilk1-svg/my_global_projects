//
//  ECDeviceInfoViewController.m
//  ECMAIN
//
//  设备信息展示和编辑视图控制器实现 - 修复版
//

#import "ECDeviceInfoViewController.h"
#import "../../Data/ECDeviceDatabase.h" // for quick device selection
#import "../../TrollStoreCore/TSUtil.h" // for spawnRoot & rootHelperPath
#import "../Core/ECDeviceInfoManager.h"
#import <UIKit/UIKit.h>

// ==========================================
// ECTimeZoneSelectionViewController
// ==========================================

@interface ECTimeZoneSelectionViewController : UITableViewController
@property(nonatomic, copy) void (^selectionBlock)(NSString *selectedTimeZone);
@end

@interface ECTimeZoneSelectionViewController () <UISearchResultsUpdating>

@property(nonatomic, strong) NSArray<NSString *> *allTimeZones;
@property(nonatomic, strong) NSArray<NSString *> *filteredTimeZones;
@property(nonatomic, strong) UISearchController *searchController;

@end

@implementation ECTimeZoneSelectionViewController

- (void)viewDidLoad {
  [super viewDidLoad];

  self.title = @"选择时区";

  // 获取所有已知时区名称并排序
  self.allTimeZones = [[NSTimeZone knownTimeZoneNames]
      sortedArrayUsingSelector:@selector(compare:)];
  self.filteredTimeZones = self.allTimeZones;

  // 设置搜索控制器
  self.searchController =
      [[UISearchController alloc] initWithSearchResultsController:nil];
  self.searchController.searchResultsUpdater = self;
  self.searchController.obscuresBackgroundDuringPresentation = NO;
  self.searchController.searchBar.placeholder =
      @"搜索时区 (例如: Shanghai, Tokyo)";
  self.navigationItem.searchController = self.searchController;
  self.definesPresentationContext = YES;

  [self.tableView registerClass:[UITableViewCell class]
         forCellReuseIdentifier:@"Cell"];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 1;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  return self.filteredTimeZones.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell =
      [tableView dequeueReusableCellWithIdentifier:@"Cell"
                                      forIndexPath:indexPath];

  NSString *timeZoneName = self.filteredTimeZones[indexPath.row];
  NSString *chineseName = [self chineseNameForTimeZone:timeZoneName];

  if (chineseName) {
    cell.textLabel.text =
        [NSString stringWithFormat:@"%@ (%@)", timeZoneName, chineseName];
  } else {
    cell.textLabel.text = timeZoneName;
  }

  return cell;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  NSString *selectedTimeZone = self.filteredTimeZones[indexPath.row];

  if (self.selectionBlock) {
    self.selectionBlock(selectedTimeZone);
  }

  [self.navigationController popViewControllerAnimated:YES];
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:
    (UISearchController *)searchController {
  NSString *searchText = searchController.searchBar.text;

  if (searchText.length > 0) {
    NSPredicate *predicate =
        [NSPredicate predicateWithFormat:@"SELF contains[cd] %@", searchText];
    self.filteredTimeZones =
        [self.allTimeZones filteredArrayUsingPredicate:predicate];
  } else {
    self.filteredTimeZones = self.allTimeZones;
  }

  [self.tableView reloadData];
}

#pragma mark - Helper

- (NSString *)chineseNameForTimeZone:(NSString *)timeZoneName {
  NSTimeZone *tz = [NSTimeZone timeZoneWithName:timeZoneName];
  NSLocale *cnLocale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
  return [tz localizedName:NSTimeZoneNameStyleGeneric locale:cnLocale];
}

@end
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

// ==========================================
// 1. Define Data Model & Country Selection VC (Moved to Top)
// ==========================================

@interface ECRegionInfo : NSObject
@property(nonatomic, copy) NSString *countryCode;
@property(nonatomic, copy) NSString *displayName; // English + Chinese
@property(nonatomic, copy) NSString *languageCode;
@property(nonatomic, copy) NSString *localeIdentifier;
@property(nonatomic, copy) NSString *currencyCode;
@property(nonatomic, copy) NSString *timezone;
@end

@implementation ECRegionInfo
@end

typedef void (^ECRegionSelectionBlock)(ECRegionInfo *info);

@interface ECCountrySelectionViewController : UITableViewController
@property(nonatomic, copy) ECRegionSelectionBlock selectionBlock;
@end

@interface ECCountrySelectionViewController () <UISearchResultsUpdating>
@property(nonatomic, strong) NSArray<ECRegionInfo *> *allRegions;
@property(nonatomic, strong) NSArray<ECRegionInfo *> *filteredRegions;
@property(nonatomic, strong) UISearchController *searchController;
@end

@implementation ECCountrySelectionViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"选择国家/地区";

  [self setupData];

  // Setup Search
  self.searchController =
      [[UISearchController alloc] initWithSearchResultsController:nil];
  self.searchController.searchResultsUpdater = self;
  self.searchController.obscuresBackgroundDuringPresentation = NO;
  self.searchController.searchBar.placeholder = @"搜索 (Search)";
  self.navigationItem.searchController = self.searchController;
  self.definesPresentationContext = YES;

  // Setup Cancel Button
  self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                           target:self
                           action:@selector(cancel)];
}

- (void)cancel {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)setupData {
  NSMutableArray *arr = [NSMutableArray array];

  // Helper block
  void (^add)(NSString *, NSString *, NSString *, NSString *, NSString *,
              NSString *) = ^(NSString *code, NSString *cnName,
                              NSString *enName, NSString *lang, NSString *curr,
                              NSString *tz) {
    ECRegionInfo *info = [ECRegionInfo new];
    info.countryCode = code;
    info.displayName = [NSString stringWithFormat:@"%@ (%@)", enName, cnName];
    info.languageCode = lang;
    info.localeIdentifier = [NSString stringWithFormat:@"%@_%@", lang, code];
    info.currencyCode = curr;
    info.timezone = tz;
    [arr addObject:info];
  };

  // Generated Global Countries
  add(@"AF", @"阿富汗", @"Afghanistan", @"ps", @"AFN", @"Asia/Kabul");
  add(@"AL", @"阿尔巴尼亚", @"Albania", @"sq", @"ALL", @"Europe/Tirane");
  add(@"DZ", @"阿尔及利亚", @"Algeria", @"ar", @"DZD", @"Africa/Algiers");
  add(@"AS", @"美属萨摩亚", @"American Samoa", @"en", @"USD",
      @"Pacific/Pago_Pago");
  add(@"AD", @"安道尔", @"Andorra", @"ca", @"EUR", @"Europe/Andorra");
  add(@"AO", @"安哥拉", @"Angola", @"pt", @"AOA", @"Africa/Luanda");
  add(@"AI", @"安圭拉", @"Anguilla", @"en", @"XCD", @"America/Anguilla");
  add(@"AQ", @"南极洲", @"Antarctica", @"en", @"AQD", @"Antarctica/McMurdo");
  add(@"AG", @"安提瓜和巴布达", @"Antigua and Barbuda", @"en", @"XCD",
      @"America/Antigua");
  add(@"AR", @"阿根廷", @"Argentina", @"es", @"ARS",
      @"America/Argentina/Buenos_Aires");
  add(@"AM", @"亚美尼亚", @"Armenia", @"hy", @"AMD", @"Asia/Yerevan");
  add(@"AW", @"阿鲁巴", @"Aruba", @"nl", @"AWG", @"America/Aruba");
  add(@"AU", @"澳大利亚", @"Australia", @"en", @"AUD", @"Australia/Sydney");
  add(@"AT", @"奥地利", @"Austria", @"de", @"EUR", @"Europe/Vienna");
  add(@"AZ", @"阿塞拜疆", @"Azerbaijan", @"az", @"AZN", @"Asia/Baku");
  add(@"BS", @"巴哈马", @"Bahamas", @"en", @"BSD", @"America/Nassau");
  add(@"BH", @"巴林", @"Bahrain", @"ar", @"BHD", @"Asia/Bahrain");
  add(@"BD", @"孟加拉国", @"Bangladesh", @"bn", @"BDT", @"Asia/Dhaka");
  add(@"BB", @"巴巴多斯", @"Barbados", @"en", @"BBD", @"America/Barbados");
  add(@"BY", @"白俄罗斯", @"Belarus", @"be", @"BYN", @"Europe/Minsk");
  add(@"BE", @"比利时", @"Belgium", @"fr", @"EUR", @"Europe/Brussels");
  add(@"BZ", @"伯利兹", @"Belize", @"en", @"BZD", @"America/Belize");
  add(@"BJ", @"贝宁", @"Benin", @"fr", @"XOF", @"Africa/Porto-Novo");
  add(@"BM", @"百慕大", @"Bermuda", @"en", @"BMD", @"Atlantic/Bermuda");
  add(@"BT", @"不丹", @"Bhutan", @"dz", @"BTN", @"Asia/Thimphu");
  add(@"BO", @"玻利维亚", @"Bolivia", @"es", @"BOB", @"America/La_Paz");
  add(@"BA", @"波黑", @"Bosnia and Herzegovina", @"bs", @"BAM",
      @"Europe/Sarajevo");
  add(@"BW", @"博茨瓦纳", @"Botswana", @"en", @"BWP", @"Africa/Gaborone");
  add(@"BV", @"布维岛", @"Bouvet Island", @"nb", @"NOK", @"Europe/Oslo");
  add(@"BR", @"巴西", @"Brazil", @"pt", @"BRL", @"America/Sao_Paulo");
  add(@"IO", @"英属印度洋领地", @"British Indian Ocean Territory", @"en",
      @"USD", @"Indian/Chagos");
  add(@"BN", @"文莱", @"Brunei Darussalam", @"ms", @"BND", @"Asia/Brunei");
  add(@"BG", @"保加利亚", @"Bulgaria", @"bg", @"BGN", @"Europe/Sofia");
  add(@"BF", @"布基纳法索", @"Burkina Faso", @"fr", @"XOF",
      @"Africa/Ouagadougou");
  add(@"BI", @"布隆迪", @"Burundi", @"fr", @"BIF", @"Africa/Bujumbura");
  add(@"KH", @"柬埔寨", @"Cambodia", @"km", @"KHR", @"Asia/Phnom_Penh");
  add(@"CM", @"喀麦隆", @"Cameroon", @"en", @"XAF", @"Africa/Douala");
  add(@"CA", @"加拿大", @"Canada", @"en", @"CAD", @"America/Toronto");
  add(@"CV", @"佛得角", @"Cape Verde", @"pt", @"CVE", @"Atlantic/Cape_Verde");
  add(@"KY", @"开曼群岛", @"Cayman Islands", @"en", @"KYD", @"America/Cayman");
  add(@"CF", @"中非", @"Central African Republic", @"fr", @"XAF",
      @"Africa/Bangui");
  add(@"TD", @"乍得", @"Chad", @"fr", @"XAF", @"Africa/Ndjamena");
  add(@"CL", @"智利", @"Chile", @"es", @"CLP", @"America/Santiago");
  add(@"CN", @"中国", @"China", @"zh-Hans", @"CNY", @"Asia/Shanghai");
  add(@"CX", @"圣诞岛", @"Christmas Island", @"en", @"AUD",
      @"Indian/Christmas");
  add(@"CC", @"科科斯（基林）群岛", @"Cocos (Keeling) Islands", @"en", @"AUD",
      @"Indian/Cocos");
  add(@"CO", @"哥伦比亚", @"Colombia", @"es", @"COP", @"America/Bogota");
  add(@"KM", @"科摩罗", @"Comoros", @"fr", @"KMF", @"Indian/Comoro");
  add(@"CG", @"刚果（布）", @"Congo", @"fr", @"XAF", @"Africa/Brazzaville");
  add(@"CD", @"刚果（金）", @"Congo, The Democratic Republic of the", @"fr",
      @"CDF", @"Africa/Kinshasa");
  add(@"CK", @"库克群岛", @"Cook Islands", @"en", @"NZD", @"Pacific/Rarotonga");
  add(@"CR", @"哥斯达黎加", @"Costa Rica", @"es", @"CRC",
      @"America/Costa_Rica");
  add(@"CI", @"科特迪瓦", @"Cote D'Ivoire", @"fr", @"XOF", @"Africa/Abidjan");
  add(@"HR", @"克罗地亚", @"Croatia", @"hr", @"HRK", @"Europe/Zagreb");
  add(@"CU", @"古巴", @"Cuba", @"es", @"CUP", @"America/Havana");
  add(@"CY", @"塞浦路斯", @"Cyprus", @"el", @"EUR", @"Asia/Nicosia");
  add(@"CZ", @"捷克", @"Czech Republic", @"cs", @"CZK", @"Europe/Prague");
  add(@"DK", @"丹麦", @"Denmark", @"da", @"DKK", @"Europe/Copenhagen");
  add(@"DJ", @"吉布提", @"Djibouti", @"fr", @"DJF", @"Africa/Djibouti");
  add(@"DM", @"多米尼克", @"Dominica", @"en", @"XCD", @"America/Dominica");
  add(@"DO", @"多米尼加共和国", @"Dominican Republic", @"es", @"DOP",
      @"America/Santo_Domingo");
  add(@"EC", @"厄瓜多尔", @"Ecuador", @"es", @"USD", @"America/Guayaquil");
  add(@"EG", @"埃及", @"Egypt", @"ar", @"EGP", @"Africa/Cairo");
  add(@"SV", @"萨尔瓦多", @"El Salvador", @"es", @"USD",
      @"America/El_Salvador");
  add(@"GQ", @"赤道几内亚", @"Equatorial Guinea", @"es", @"XAF",
      @"Africa/Malabo");
  add(@"ER", @"厄立特里亚", @"Eritrea", @"ti", @"ERN", @"Africa/Asmara");
  add(@"EE", @"爱沙尼亚", @"Estonia", @"et", @"EUR", @"Europe/Tallinn");
  add(@"ET", @"埃塞俄比亚", @"Ethiopia", @"am", @"ETB", @"Africa/Addis_Ababa");
  add(@"FK", @"福克兰群岛", @"Falkland Islands (Malvinas)", @"en", @"FKP",
      @"Atlantic/Stanley");
  add(@"FO", @"法罗群岛", @"Faroe Islands", @"fo", @"DKK", @"Atlantic/Faroe");
  add(@"FJ", @"斐济", @"Fiji", @"en", @"FJD", @"Pacific/Fiji");
  add(@"FI", @"芬兰", @"Finland", @"fi", @"EUR", @"Europe/Helsinki");
  add(@"FR", @"法国", @"France", @"fr", @"EUR", @"Europe/Paris");
  add(@"GF", @"法属圭亚那", @"French Guiana", @"fr", @"EUR",
      @"America/Cayenne");
  add(@"PF", @"法属波利尼西亚", @"French Polynesia", @"fr", @"XPF",
      @"Pacific/Tahiti");
  add(@"TF", @"法属南部领地", @"French Southern Territories", @"fr", @"EUR",
      @"Indian/Kerguelen");
  add(@"GA", @"加蓬", @"Gabon", @"fr", @"XAF", @"Africa/Libreville");
  add(@"GM", @"冈比亚", @"Gambia", @"en", @"GMD", @"Africa/Banjul");
  add(@"GE", @"格鲁吉亚", @"Georgia", @"ka", @"GEL", @"Asia/Tbilisi");
  add(@"DE", @"德国", @"Germany", @"de", @"EUR", @"Europe/Berlin");
  add(@"GH", @"加纳", @"Ghana", @"en", @"GHS", @"Africa/Accra");
  add(@"GI", @"直布罗陀", @"Gibraltar", @"en", @"GIP", @"Europe/Gibraltar");
  add(@"GR", @"希腊", @"Greece", @"el", @"EUR", @"Europe/Athens");
  add(@"GL", @"格陵兰", @"Greenland", @"kl", @"DKK", @"America/Godthab");
  add(@"GD", @"格林纳达", @"Grenada", @"en", @"XCD", @"America/Grenada");
  add(@"GP", @"瓜德罗普", @"Guadeloupe", @"fr", @"EUR", @"America/Guadeloupe");
  add(@"GU", @"关岛", @"Guam", @"en", @"USD", @"Pacific/Guam");
  add(@"GT", @"危地马拉", @"Guatemala", @"es", @"GTQ", @"America/Guatemala");
  add(@"GG", @"根西", @"Guernsey", @"en", @"GBP", @"Europe/Guernsey");
  add(@"GN", @"几内亚", @"Guinea", @"fr", @"GNF", @"Africa/Conakry");
  add(@"GW", @"几内亚比绍", @"Guinea-Bissau", @"pt", @"XOF", @"Africa/Bissau");
  add(@"GY", @"圭亚那", @"Guyana", @"en", @"GYD", @"America/Guyana");
  add(@"HT", @"海地", @"Haiti", @"fr", @"HTG", @"America/Port-au-Prince");
  add(@"HM", @"赫德岛和麦克唐纳群岛", @"Heard Island and McDonald Islands",
      @"en", @"AUD", @"Indian/Maldives");
  add(@"VA", @"梵蒂冈", @"Holy See (Vatican City State)", @"it", @"EUR",
      @"Europe/Vatican");
  add(@"HN", @"洪都拉斯", @"Honduras", @"es", @"HNL", @"America/Tegucigalpa");
  add(@"HK", @"中国香港", @"Hong Kong", @"zh-Hant", @"HKD", @"Asia/Hong_Kong");
  add(@"HU", @"匈牙利", @"Hungary", @"hu", @"HUF", @"Europe/Budapest");
  add(@"IS", @"冰岛", @"Iceland", @"is", @"ISK", @"Atlantic/Reykjavik");
  add(@"IN", @"印度", @"India", @"en", @"INR", @"Asia/Kolkata");
  add(@"ID", @"印度尼西亚", @"Indonesia", @"id", @"IDR", @"Asia/Jakarta");
  add(@"IR", @"伊朗", @"Iran, Islamic Republic of", @"fa", @"IRR",
      @"Asia/Tehran");
  add(@"IQ", @"伊拉克", @"Iraq", @"ar", @"IQD", @"Asia/Baghdad");
  add(@"IE", @"爱尔兰", @"Ireland", @"ga", @"EUR", @"Europe/Dublin");
  add(@"IM", @"马恩岛", @"Isle of Man", @"en", @"GBP", @"Europe/Isle_of_Man");
  add(@"IL", @"以色列", @"Israel", @"he", @"ILS", @"Asia/Jerusalem");
  add(@"IT", @"意大利", @"Italy", @"it", @"EUR", @"Europe/Rome");
  add(@"JM", @"牙买加", @"Jamaica", @"en", @"JMD", @"America/Jamaica");
  add(@"JP", @"日本", @"Japan", @"ja", @"JPY", @"Asia/Tokyo");
  add(@"JE", @"泽西", @"Jersey", @"en", @"GBP", @"Europe/Jersey");
  add(@"JO", @"约旦", @"Jordan", @"ar", @"JOD", @"Asia/Amman");
  add(@"KZ", @"哈萨克斯坦", @"Kazakhstan", @"kk", @"KZT", @"Asia/Almaty");
  add(@"KE", @"肯尼亚", @"Kenya", @"sw", @"KES", @"Africa/Nairobi");
  add(@"KI", @"基里巴斯", @"Kiribati", @"en", @"AUD", @"Pacific/Tarawa");
  add(@"KP", @"朝鲜", @"Korea, Democratic People's Republic of", @"ko", @"KPW",
      @"Asia/Pyongyang");
  add(@"KR", @"韩国", @"South Korea", @"ko", @"KRW", @"Asia/Seoul");
  add(@"KW", @"科威特", @"Kuwait", @"ar", @"KWD", @"Asia/Kuwait");
  add(@"KG", @"吉尔吉斯斯坦", @"Kyrgyzstan", @"ky", @"KGS", @"Asia/Bishkek");
  add(@"LA", @"老挝", @"Lao People's Democratic Republic", @"lo", @"LAK",
      @"Asia/Vientiane");
  add(@"LV", @"拉脱维亚", @"Latvia", @"lv", @"EUR", @"Europe/Riga");
  add(@"LB", @"黎巴嫩", @"Lebanon", @"ar", @"LBP", @"Asia/Beirut");
  add(@"LS", @"莱索托", @"Lesotho", @"st", @"LSL", @"Africa/Maseru");
  add(@"LR", @"利比里亚", @"Liberia", @"en", @"LRD", @"Africa/Monrovia");
  add(@"LY", @"利比亚", @"Libyan Arab Jamahiriya", @"ar", @"LYD",
      @"Africa/Tripoli");
  add(@"LI", @"列支敦士登", @"Liechtenstein", @"de", @"CHF", @"Europe/Vaduz");
  add(@"LT", @"立陶宛", @"Lithuania", @"lt", @"EUR", @"Europe/Vilnius");
  add(@"LU", @"卢森堡", @"Luxembourg", @"fr", @"EUR", @"Europe/Luxembourg");
  add(@"MO", @"中国澳门", @"Macao", @"zh-Hant", @"MOP", @"Asia/Macau");
  add(@"MK", @"北马其顿", @"Macedonia, The Former Yugoslav Republic of", @"mk",
      @"MKD", @"Europe/Skopje");
  add(@"MG", @"马达加斯加", @"Madagascar", @"fr", @"MGA",
      @"Indian/Antananarivo");
  add(@"MW", @"马拉维", @"Malawi", @"en", @"MWK", @"Africa/Blantyre");
  add(@"MY", @"马来西亚", @"Malaysia", @"ms", @"MYR", @"Asia/Kuala_Lumpur");
  add(@"MV", @"马尔代夫", @"Maldives", @"dv", @"MVR", @"Indian/Maldives");
  add(@"ML", @"马里", @"Mali", @"fr", @"XOF", @"Africa/Bamako");
  add(@"MT", @"马耳他", @"Malta", @"mt", @"EUR", @"Europe/Malta");
  add(@"MH", @"马绍尔群岛", @"Marshall Islands", @"en", @"USD",
      @"Pacific/Majuro");
  add(@"MQ", @"马提尼克", @"Martinique", @"fr", @"EUR", @"America/Martinique");
  add(@"MR", @"毛里塔尼亚", @"Mauritania", @"ar", @"MRU", @"Africa/Nouakchott");
  add(@"MU", @"毛里求斯", @"Mauritius", @"en", @"MUR", @"Indian/Mauritius");
  add(@"YT", @"马约特", @"Mayotte", @"fr", @"EUR", @"Indian/Mayotte");
  add(@"MX", @"墨西哥", @"Mexico", @"es", @"MXN", @"America/Mexico_City");
  add(@"FM", @"密克罗尼西亚", @"Micronesia, Federated States of", @"en", @"USD",
      @"Pacific/Pohnpei");
  add(@"MD", @"摩尔多瓦", @"Moldova, Republic of", @"ro", @"MDL",
      @"Europe/Chisinau");
  add(@"MC", @"摩纳哥", @"Monaco", @"fr", @"EUR", @"Europe/Monaco");
  add(@"MN", @"蒙古", @"Mongolia", @"mn", @"MNT", @"Asia/Ulaanbaatar");
  add(@"ME", @"黑山", @"Montenegro", @"sr", @"EUR", @"Europe/Podgorica");
  add(@"MS", @"蒙特塞拉特", @"Montserrat", @"en", @"XCD",
      @"America/Montserrat");
  add(@"MA", @"摩洛哥", @"Morocco", @"ar", @"MAD", @"Africa/Casablanca");
  add(@"MZ", @"莫桑比克", @"Mozambique", @"pt", @"MZN", @"Africa/Maputo");
  add(@"MM", @"缅甸", @"Myanmar", @"my", @"MMK", @"Asia/Yangon");
  add(@"NA", @"纳米比亚", @"Namibia", @"en", @"NAD", @"Africa/Windhoek");
  add(@"NR", @"瑙鲁", @"Nauru", @"en", @"AUD", @"Pacific/Nauru");
  add(@"NP", @"尼泊尔", @"Nepal", @"ne", @"NPR", @"Asia/Kathmandu");
  add(@"NL", @"荷兰", @"Netherlands", @"nl", @"EUR", @"Europe/Amsterdam");
  add(@"NC", @"新喀里多尼亚", @"New Caledonia", @"fr", @"XPF",
      @"Pacific/Noumea");
  add(@"NZ", @"新西兰", @"New Zealand", @"en", @"NZD", @"Pacific/Auckland");
  add(@"NI", @"尼加拉瓜", @"Nicaragua", @"es", @"NIO", @"America/Managua");
  add(@"NE", @"尼日尔", @"Niger", @"fr", @"XOF", @"Africa/Niamey");
  add(@"NG", @"尼日利亚", @"Nigeria", @"en", @"NGN", @"Africa/Lagos");
  add(@"NU", @"纽埃", @"Niue", @"en", @"NZD", @"Pacific/Niue");
  add(@"NF", @"诺福克岛", @"Norfolk Island", @"en", @"AUD", @"Pacific/Norfolk");
  add(@"MP", @"北马里亚纳群岛", @"Northern Mariana Islands", @"en", @"USD",
      @"Pacific/Saipan");
  add(@"NO", @"挪威", @"Norway", @"nb", @"NOK", @"Europe/Oslo");
  add(@"OM", @"阿曼", @"Oman", @"ar", @"OMR", @"Asia/Muscat");
  add(@"PK", @"巴基斯坦", @"Pakistan", @"ur", @"PKR", @"Asia/Karachi");
  add(@"PW", @"帕劳", @"Palau", @"en", @"USD", @"Pacific/Palau");
  add(@"PS", @"巴勒斯坦", @"Palestinian Territory, Occupied", @"ar", @"ILS",
      @"Asia/Gaza");
  add(@"PA", @"巴拿马", @"Panama", @"es", @"PAB", @"America/Panama");
  add(@"PG", @"巴布亚新几内亚", @"Papua New Guinea", @"en", @"PGK",
      @"Pacific/Port_Moresby");
  add(@"PY", @"巴拉圭", @"Paraguay", @"es", @"PYG", @"America/Asuncion");
  add(@"PE", @"秘鲁", @"Peru", @"es", @"PEN", @"America/Lima");
  add(@"PH", @"菲律宾", @"Philippines", @"en", @"PHP", @"Asia/Manila");
  add(@"PN", @"皮特凯恩", @"Pitcairn", @"en", @"NZD", @"Pacific/Pitcairn");
  add(@"PL", @"波兰", @"Poland", @"pl", @"PLN", @"Europe/Warsaw");
  add(@"PT", @"葡萄牙", @"Portugal", @"pt", @"EUR", @"Europe/Lisbon");
  add(@"PR", @"波多黎各", @"Puerto Rico", @"es", @"USD",
      @"America/Puerto_Rico");
  add(@"QA", @"卡塔尔", @"Qatar", @"ar", @"QAR", @"Asia/Qatar");
  add(@"RE", @"留尼汪", @"Reunion", @"fr", @"EUR", @"Indian/Reunion");
  add(@"RO", @"罗马尼亚", @"Romania", @"ro", @"RON", @"Europe/Bucharest");
  add(@"RU", @"俄罗斯", @"Russian Federation", @"ru", @"RUB", @"Europe/Moscow");
  add(@"RW", @"卢旺达", @"Rwanda", @"rw", @"RWF", @"Africa/Kigali");
  add(@"BL", @"圣巴泰勒米", @"Saint Barthelemy", @"fr", @"EUR",
      @"America/St_Barthelemy");
  add(@"SH", @"圣赫勒拿", @"Saint Helena", @"en", @"SHP",
      @"Atlantic/St_Helena");
  add(@"KN", @"圣基茨和尼维斯", @"Saint Kitts and Nevis", @"en", @"XCD",
      @"America/St_Kitts");
  add(@"LC", @"圣卢西亚", @"Saint Lucia", @"en", @"XCD", @"America/St_Lucia");
  add(@"MF", @"圣马丁", @"Saint Martin", @"fr", @"EUR", @"America/Marigot");
  add(@"PM", @"圣皮埃尔和密克隆", @"Saint Pierre and Miquelon", @"fr", @"EUR",
      @"America/Miquelon");
  add(@"VC", @"圣文森特和格林纳丁斯", @"Saint Vincent and the Grenadines",
      @"en", @"XCD", @"America/St_Vincent");
  add(@"WS", @"萨摩亚", @"Samoa", @"sm", @"WST", @"Pacific/Apia");
  add(@"SM", @"圣马力诺", @"San Marino", @"it", @"EUR", @"Europe/San_Marino");
  add(@"ST", @"圣多美和普林西比", @"Sao Tome and Principe", @"pt", @"STD",
      @"Africa/Sao_Tome");
  add(@"SA", @"沙特阿拉伯", @"Saudi Arabia", @"ar", @"SAR", @"Asia/Riyadh");
  add(@"SN", @"塞内加尔", @"Senegal", @"fr", @"XOF", @"Africa/Dakar");
  add(@"RS", @"塞尔维亚", @"Serbia", @"sr", @"RSD", @"Europe/Belgrade");
  add(@"SC", @"塞舌尔", @"Seychelles", @"fr", @"SCR", @"Indian/Mahe");
  add(@"SL", @"塞拉利昂", @"Sierra Leone", @"en", @"SLL", @"Africa/Freetown");
  add(@"SG", @"新加坡", @"Singapore", @"en", @"SGD", @"Asia/Singapore");
  add(@"SX", @"荷属圣马丁", @"Sint Maarten (Dutch part)", @"nl", @"ANG",
      @"America/Lower_Princes");
  add(@"SK", @"斯洛伐克", @"Slovakia", @"sk", @"EUR", @"Europe/Bratislava");
  add(@"SI", @"斯洛文尼亚", @"Slovenia", @"sl", @"EUR", @"Europe/Ljubljana");
  add(@"SB", @"所罗门群岛", @"Solomon Islands", @"en", @"SBD",
      @"Pacific/Guadalcanal");
  add(@"SO", @"索马里", @"Somalia", @"so", @"SOS", @"Africa/Mogadishu");
  add(@"ZA", @"南非", @"South Africa", @"en", @"ZAR", @"Africa/Johannesburg");
  add(@"GS", @"南乔治亚和南桑威奇群岛",
      @"South Georgia and the South Sandwich Islands", @"en", @"GBP",
      @"Atlantic/South_Georgia");
  add(@"SS", @"南苏丹", @"South Sudan", @"en", @"SSP", @"Africa/Juba");
  add(@"ES", @"西班牙", @"Spain", @"es", @"EUR", @"Europe/Madrid");
  add(@"LK", @"斯里兰卡", @"Sri Lanka", @"si", @"LKR", @"Asia/Colombo");
  add(@"SD", @"苏丹", @"Sudan", @"ar", @"SDG", @"Africa/Khartoum");
  add(@"SR", @"苏里南", @"Suriname", @"nl", @"SRD", @"America/Paramaribo");
  add(@"SJ", @"斯瓦尔巴和扬马延", @"Svalbard and Jan Mayen", @"nb", @"NOK",
      @"Arctic/Longyearbyen");
  add(@"SZ", @"斯威士兰", @"Swaziland", @"en", @"SZL", @"Africa/Mbabane");
  add(@"SE", @"瑞典", @"Sweden", @"sv", @"SEK", @"Europe/Stockholm");
  add(@"CH", @"瑞士", @"Switzerland", @"de", @"CHF", @"Europe/Zurich");
  add(@"SY", @"叙利亚", @"Syrian Arab Republic", @"ar", @"SYP",
      @"Asia/Damascus");
  add(@"TW", @"中国台湾", @"Taiwan, Province of China", @"zh-Hant", @"TWD",
      @"Asia/Taipei");
  add(@"TJ", @"塔吉克斯坦", @"Tajikistan", @"tg", @"TJS", @"Asia/Dushanbe");
  add(@"TZ", @"坦桑尼亚", @"Tanzania, United Republic of", @"sw", @"TZS",
      @"Africa/Dar_es_Salaam");
  add(@"TH", @"泰国", @"Thailand", @"th", @"THB", @"Asia/Bangkok");
  add(@"TL", @"东帝汶", @"Timor-Leste", @"pt", @"USD", @"Asia/Dili");
  add(@"TG", @"多哥", @"Togo", @"fr", @"XOF", @"Africa/Lome");
  add(@"TK", @"托克劳", @"Tokelau", @"en", @"NZD", @"Pacific/Fakaofo");
  add(@"TO", @"汤加", @"Tonga", @"en", @"TOP", @"Pacific/Tongatapu");
  add(@"TT", @"特立尼达和多巴哥", @"Trinidad and Tobago", @"en", @"TTD",
      @"America/Port_of_Spain");
  add(@"TN", @"突尼斯", @"Tunisia", @"ar", @"TND", @"Africa/Tunis");
  add(@"TR", @"土耳其", @"Turkey", @"tr", @"TRY", @"Europe/Istanbul");
  add(@"TM", @"土库曼斯坦", @"Turkmenistan", @"tk", @"TMT", @"Asia/Ashgabat");
  add(@"TC", @"特克斯和凯科斯群岛", @"Turks and Caicos Islands", @"en", @"USD",
      @"America/Grand_Turk");
  add(@"TV", @"图瓦卢", @"Tuvalu", @"en", @"AUD", @"Pacific/Funafuti");
  add(@"UG", @"乌干达", @"Uganda", @"en", @"UGX", @"Africa/Kampala");
  add(@"UA", @"乌克兰", @"Ukraine", @"uk", @"UAH", @"Europe/Kiev");
  add(@"AE", @"阿联酋", @"United Arab Emirates", @"ar", @"AED", @"Asia/Dubai");
  add(@"GB", @"英国", @"United Kingdom", @"en", @"GBP", @"Europe/London");
  add(@"US", @"美国", @"United States", @"en", @"USD", @"America/New_York");
  add(@"UM", @"美国本土外小岛屿", @"United States Minor Outlying Islands",
      @"en", @"USD", @"Pacific/Wake");
  add(@"UY", @"乌拉圭", @"Uruguay", @"es", @"UYU", @"America/Montevideo");
  add(@"UZ", @"乌兹别克斯坦", @"Uzbekistan", @"uz", @"UZS", @"Asia/Tashkent");
  add(@"VU", @"瓦努阿图", @"Vanuatu", @"en", @"VUV", @"Pacific/Efate");
  add(@"VE", @"委内瑞拉", @"Venezuela", @"es", @"VEF", @"America/Caracas");
  add(@"VN", @"越南", @"Viet Nam", @"vi", @"VND", @"Asia/Ho_Chi_Minh");
  add(@"VG", @"英属维尔京群岛", @"Virgin Islands, British", @"en", @"USD",
      @"America/Tortola");
  add(@"VI", @"美属维尔京群岛", @"Virgin Islands, U.S.", @"en", @"USD",
      @"America/St_Thomas");
  add(@"WF", @"瓦利斯和富图纳", @"Wallis and Futuna", @"fr", @"XPF",
      @"Pacific/Wallis");
  add(@"EH", @"西撒哈拉", @"Western Sahara", @"ar", @"MAD", @"Africa/El_Aaiun");
  add(@"YE", @"也门", @"Yemen", @"ar", @"YER", @"Asia/Aden");
  add(@"ZM", @"赞比亚", @"Zambia", @"en", @"ZMW", @"Africa/Lusaka");
  add(@"ZW", @"津巴布韦", @"Zimbabwe", @"en", @"USD", @"Africa/Harare");

  self.allRegions = arr;
  self.filteredRegions = arr;
}

#pragma mark - TableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 1;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  return self.filteredRegions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                  reuseIdentifier:@"Cell"];
  }

  ECRegionInfo *info = self.filteredRegions[indexPath.row];
  cell.textLabel.text = info.displayName;
  cell.detailTextLabel.text = info.countryCode;

  return cell;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  ECRegionInfo *info = self.filteredRegions[indexPath.row];
  if (self.selectionBlock) {
    self.selectionBlock(info);
  }
  [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:
    (UISearchController *)searchController {
  NSString *text = searchController.searchBar.text;
  if (text.length == 0) {
    self.filteredRegions = self.allRegions;
  } else {
    NSPredicate *pred = [NSPredicate
        predicateWithFormat:
            @"countryCode CONTAINS[cd] %@ OR displayName CONTAINS[cd] %@", text,
            text];
    self.filteredRegions = [self.allRegions filteredArrayUsingPredicate:pred];
  }
  [self.tableView reloadData];
}

@end

@interface ECDeviceInfoViewController ()
@property(nonatomic, strong) ECDeviceInfoManager *manager;
@property(nonatomic, strong) UIButton *saveButton;
@property(nonatomic, strong) UIButton *resetButton;
// Quick Selection Properties
@property(nonatomic, strong) ECDeviceModel *quickSelectedModel;
@property(nonatomic, strong) ECSystemVersion *quickSelectedVersion;
@property(nonatomic, strong) ECCarrierInfo *quickSelectedCarrier;
@property(nonatomic, strong) UILabel *quickModelLabel;
@property(nonatomic, strong) UILabel *quickVersionLabel;
@property(nonatomic, strong) UILabel *quickCarrierLabel;
@end

@implementation ECDeviceInfoViewController

- (void)viewDidLoad {
  [super viewDidLoad];

  self.title = @"设备信息";
  self.manager = [ECDeviceInfoManager sharedManager];

  // 设置 TableView 样式
  self.tableView.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1.0];
  self.tableView.separatorColor = [UIColor colorWithWhite:0.2 alpha:1.0];

  // CRITICAL: Allow immediate touch response in header
  self.tableView.delaysContentTouches = NO;
  for (UIView *view in self.tableView.subviews) {
    if ([view isKindOfClass:[UIScrollView class]]) {
      ((UIScrollView *)view).delaysContentTouches = NO;
    }
  }

  // 创建快速选择头部
  [self setupQuickSelectionHeader];

  // 创建底部按钮
  [self setupToolbar];

  // 添加下拉刷新
  UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
  refreshControl.tintColor = [UIColor whiteColor];
  [refreshControl addTarget:self
                     action:@selector(refreshData)
           forControlEvents:UIControlEventValueChanged];
  self.refreshControl = refreshControl;

  // 导航栏右侧按钮
  UIBarButtonItem *infoButton = [[UIBarButtonItem alloc]
      initWithImage:[UIImage systemImageNamed:@"info.circle"]
              style:UIBarButtonItemStylePlain
             target:self
             action:@selector(showInfo)];

  // 如果有 cancelBlock（从注入安装流程调用），添加取消按钮
  if (self.cancelBlock) {
    UIBarButtonItem *cancelButton = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                             target:self
                             action:@selector(cancelButtonPressed)];
    self.navigationItem.leftBarButtonItem = cancelButton;
  }

  // 如果指定了目标配置路径，加载该配置
  if (self.targetConfigPath) {
    NSLog(@"[ECDeviceInfoVC] viewDidLoad: 发现 targetConfigPath: %@",
          self.targetConfigPath);
    [self.manager loadConfigFromPath:self.targetConfigPath];
    self.title = self.isEditingMode ? @"配置伪装参数" : @"设备信息";
  } else {
    NSLog(@"[ECDeviceInfoVC] viewDidLoad: 未指定 "
          @"targetConfigPath，使用默认/全局配置");
  }
}

#pragma mark - Quick Selection Header

- (void)setupQuickSelectionHeader {
  // Use UIScreen width to avoid zero-width issues in viewDidLoad
  CGFloat width = [UIScreen mainScreen].bounds.size.width;
  CGFloat padding = 16;
  CGFloat rowHeight = 44;
  CGFloat rowSpacing = 12;
  // height = top padding + 4 rows + 3 spaces + bottom padding
  CGFloat headerHeight = 20 + (rowHeight * 4) + (rowSpacing * 3) + 20;

  UIView *headerView =
      [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, headerHeight)];
  headerView.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1.0];
  headerView.userInteractionEnabled = YES;
  headerView.autoresizingMask = UIViewAutoresizingFlexibleWidth;

  CGFloat y = 20;

  // Row 0: 仅伪装克隆开关
  UIView *cloneOnlyRow = [[UIView alloc]
      initWithFrame:CGRectMake(padding, y, width - padding * 2, rowHeight)];
  cloneOnlyRow.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
  cloneOnlyRow.layer.cornerRadius = 8;
  cloneOnlyRow.layer.borderWidth = 1;
  cloneOnlyRow.layer.borderColor =
      [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.6].CGColor;
  cloneOnlyRow.autoresizingMask = UIViewAutoresizingFlexibleWidth;

  UILabel *cloneOnlyLabel = [[UILabel alloc]
      initWithFrame:CGRectMake(12, 0, cloneOnlyRow.frame.size.width - 80,
                               rowHeight)];
  cloneOnlyLabel.text = @"🛡️ 仅伪装克隆（不伪装设备）";
  cloneOnlyLabel.textColor = [UIColor colorWithRed:0.4
                                             green:0.8
                                              blue:1.0
                                             alpha:1.0];
  cloneOnlyLabel.font = [UIFont boldSystemFontOfSize:14];
  cloneOnlyLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  [cloneOnlyRow addSubview:cloneOnlyLabel];

  UISwitch *cloneOnlySwitch = [[UISwitch alloc]
      initWithFrame:CGRectMake(cloneOnlyRow.frame.size.width - 63,
                               (rowHeight - 31) / 2, 51, 31)];
  cloneOnlySwitch.on = self.manager.cloneOnlyMode;
  cloneOnlySwitch.onTintColor = [UIColor colorWithRed:0.2
                                                green:0.6
                                                 blue:1.0
                                                alpha:1.0];
  cloneOnlySwitch.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
  [cloneOnlySwitch addTarget:self
                      action:@selector(cloneOnlyModeChanged:)
            forControlEvents:UIControlEventValueChanged];
  [cloneOnlyRow addSubview:cloneOnlySwitch];
  [headerView addSubview:cloneOnlyRow];
  y += rowHeight + rowSpacing;

  // Row 1: Device Model Dropdown
  UIButton *btn1 = [self
      createDropdownButtonWithPlaceholder:@"选择设备型号..."
                                    value:nil
                                   action:@selector(quickSelectModelTapped)
                                    frame:CGRectMake(padding, y,
                                                     width - padding * 2,
                                                     rowHeight)];
  self.quickModelLabel = [btn1 viewWithTag:101]; // Label inside button
  [headerView addSubview:btn1];
  y += rowHeight + rowSpacing;

  // Row 2: iOS Version Dropdown
  UIButton *btn2 = [self
      createDropdownButtonWithPlaceholder:@"选择系统版本..."
                                    value:nil
                                   action:@selector(quickSelectVersionTapped)
                                    frame:CGRectMake(padding, y,
                                                     width - padding * 2,
                                                     rowHeight)];
  self.quickVersionLabel = [btn2 viewWithTag:101];
  [headerView addSubview:btn2];
  y += rowHeight + rowSpacing;

  // Row 3: Carrier Dropdown
  UIButton *btn3 = [self
      createDropdownButtonWithPlaceholder:@"选择运营商..."
                                    value:nil
                                   action:@selector(quickSelectCarrierTapped)
                                    frame:CGRectMake(padding, y,
                                                     width - padding * 2,
                                                     rowHeight)];
  self.quickCarrierLabel = [btn3 viewWithTag:101];
  [headerView addSubview:btn3];

  self.tableView.tableHeaderView = headerView;
}

- (UIButton *)createDropdownButtonWithPlaceholder:(NSString *)placeholder
                                            value:(NSString *)value
                                           action:(SEL)action
                                            frame:(CGRect)frame {
  UIButton *button = [[UIButton alloc] initWithFrame:frame];
  button.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
  button.layer.cornerRadius = 8;
  button.layer.borderWidth = 1;
  button.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
  button.autoresizingMask = UIViewAutoresizingFlexibleWidth;

  [button addTarget:self
                action:action
      forControlEvents:UIControlEventTouchUpInside];
  // Highlight effect
  [button addTarget:self
                action:@selector(buttonHighlight:)
      forControlEvents:UIControlEventTouchDown];
  [button addTarget:self
                action:@selector(buttonUnhighlight:)
      forControlEvents:UIControlEventTouchUpInside |
                       UIControlEventTouchUpOutside |
                       UIControlEventTouchCancel];

  // Main Label (Left aligned, displays placeholder or value)
  UILabel *label =
      [[UILabel alloc] initWithFrame:CGRectMake(12, 0, frame.size.width - 40,
                                                frame.size.height)];
  label.text = value ?: placeholder;
  label.textColor = value ? [UIColor whiteColor] : [UIColor lightGrayColor];
  label.font = [UIFont systemFontOfSize:15];
  label.textAlignment = NSTextAlignmentLeft;
  label.tag = 101;
  label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  [button addSubview:label];

  // Arrow Icon (Right aligned)
  UILabel *arrow =
      [[UILabel alloc] initWithFrame:CGRectMake(frame.size.width - 30, 0, 20,
                                                frame.size.height)];
  arrow.text = @"▼"; // Dropdown arrow
  arrow.textColor = [UIColor grayColor];
  arrow.font = [UIFont systemFontOfSize:12];
  arrow.textAlignment = NSTextAlignmentCenter;
  arrow.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
  [button addSubview:arrow];

  return button;
}

- (void)buttonHighlight:(UIButton *)sender {
  sender.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
  sender.layer.borderColor = [UIColor systemBlueColor].CGColor;
}

- (void)buttonUnhighlight:(UIButton *)sender {
  sender.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
  sender.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
}

#pragma mark - Clone Only Mode

- (void)cloneOnlyModeChanged:(UISwitch *)sender {
  if (sender.on) {
    // 开启时弹出确认
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"仅伪装克隆模式"
                         message:
                             @"开启后将暴露真实设备信息给 TikTok，"
                             @"仅隐藏克隆痕迹（Bundle ID、Keychain 等）。\n\n"
                             @"适用于：不需要伪装设备，只需要多开的场景。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert
        addAction:[UIAlertAction actionWithTitle:@"确认开启"
                                           style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *action) {
                                           self.manager.cloneOnlyMode = YES;
                                           [self.tableView reloadData];
                                         }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) {
                                              sender.on = NO;
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
  } else {
    self.manager.cloneOnlyMode = NO;
    [self.tableView reloadData];
  }
}

#pragma mark - Quick Selection Actions

- (void)quickSelectModelTapped {
  NSArray<ECDeviceModel *> *models =
      [[ECDeviceDatabase shared] alliPhoneModels];

  UIAlertController *sheet = [UIAlertController
      alertControllerWithTitle:@"选择设备型号"
                       message:nil
                preferredStyle:UIAlertControllerStyleActionSheet];

  for (ECDeviceModel *model in models) {
    [sheet addAction:[UIAlertAction
                         actionWithTitle:model.displayName
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *action) {
                                   self.quickSelectedModel = model;
                                   self.quickModelLabel.text =
                                       model.displayName;
                                   self.quickModelLabel.textColor =
                                       [UIColor whiteColor];

                                   // Reset version selection
                                   self.quickSelectedVersion = nil;
                                   self.quickVersionLabel.text =
                                       @"选择系统版本..."; // Placeholder
                                   self.quickVersionLabel.textColor =
                                       [UIColor lightGrayColor];

                                   // Auto-apply model fields
                                   [self applyQuickSelectedModel:model];
                                 }]];
  }

  [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  // iPad support
  if (sheet.popoverPresentationController) {
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(self.view.bounds.size.width / 2, 100, 0, 0);
  }

  [self presentViewController:sheet animated:YES completion:nil];
}

- (void)quickSelectVersionTapped {
  if (!self.quickSelectedModel) {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"提示"
                         message:@"请先选择设备型号"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    return;
  }

  NSArray<ECSystemVersion *> *versions =
      [[ECDeviceDatabase shared] versionsForModel:self.quickSelectedModel];

  UIAlertController *sheet = [UIAlertController
      alertControllerWithTitle:@"选择 iOS 版本"
                       message:[NSString
                                   stringWithFormat:@"适用于 %@",
                                                    self.quickSelectedModel
                                                        .displayName]
                preferredStyle:UIAlertControllerStyleActionSheet];

  for (ECSystemVersion *ver in versions) {
    NSString *title = [NSString
        stringWithFormat:@"iOS %@ (%@)", ver.osVersion, ver.buildVersion];
    [sheet
        addAction:[UIAlertAction actionWithTitle:title
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action) {
                                           self.quickSelectedVersion = ver;
                                           self.quickVersionLabel.text = title;
                                           self.quickVersionLabel.textColor =
                                               [UIColor whiteColor];

                                           // Auto-apply version fields
                                           [self applyQuickSelectedVersion:ver];
                                         }]];
  }

  [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  if (sheet.popoverPresentationController) {
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(self.view.bounds.size.width / 2, 150, 0, 0);
  }

  [self presentViewController:sheet animated:YES completion:nil];
}

- (void)quickSelectCarrierTapped {
  NSArray<ECCarrierInfo *> *carriers =
      [[ECDeviceDatabase shared] supportedCarriers];

  UIAlertController *sheet = [UIAlertController
      alertControllerWithTitle:@"选择运营商"
                       message:@"按地区分组"
                preferredStyle:UIAlertControllerStyleActionSheet];

  // Use NSLocale for global Chinese country name lookup
  NSLocale *cnLocale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];

  for (ECCarrierInfo *carrier in carriers) {
    NSString *cnName = [cnLocale displayNameForKey:NSLocaleCountryCode
                                             value:carrier.countryCode];
    if (!cnName) {
      cnName = carrier.countryCode; // Fallback
    }

    NSString *title =
        [NSString stringWithFormat:@"%@ (%@) - %@", carrier.countryCode, cnName,
                                   carrier.carrierName];

    [sheet addAction:[UIAlertAction
                         actionWithTitle:title
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *action) {
                                   self.quickSelectedCarrier = carrier;
                                   self.quickCarrierLabel.text = title;
                                   self.quickCarrierLabel.textColor =
                                       [UIColor whiteColor];

                                   // Auto-apply carrier fields
                                   [self applyQuickSelectedCarrier:carrier];
                                 }]];
  }

  [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  if (sheet.popoverPresentationController) {
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(self.view.bounds.size.width / 2, 200, 0, 0);
  }

  [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showFullCarrierList {
  // Use a table view controller for full list
  UITableViewController *listVC =
      [[UITableViewController alloc] initWithStyle:UITableViewStylePlain];
  listVC.title = @"选择运营商";

  NSArray<ECCarrierInfo *> *carriers =
      [[ECDeviceDatabase shared] supportedCarriers];

  // Store carriers in associated object for the closure
  objc_setAssociatedObject(listVC, "carriers", carriers,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(listVC, "parentVC", self, OBJC_ASSOCIATION_ASSIGN);

  // Simple implementation using blocks
  UINavigationController *nav =
      [[UINavigationController alloc] initWithRootViewController:listVC];
  nav.modalPresentationStyle = UIModalPresentationFormSheet;

  listVC.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                           target:listVC
                           action:@selector(dismissVC)];

  [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Apply Quick Selections

- (void)applyQuickSelectedModel:(ECDeviceModel *)model {
  // Find and update all model-related items
  // FIXED: Key mappings matched with ECDeviceInfoManager
  // FIXED: Format specifiers %ld for NSInteger properties
  NSDictionary *updates = @{
    @"machineModel" : model.machineId,
    @"deviceModel" : @"iPhone",
    @"deviceName" : model.displayName,
    @"productName" : model.displayName, // Added product name update
    @"screenWidth" :
        [NSString stringWithFormat:@"%ld", (long)model.screenWidth],
    @"screenHeight" :
        [NSString stringWithFormat:@"%ld", (long)model.screenHeight],
    @"screenScale" :
        [NSString stringWithFormat:@"%.1f", model.screenScale], // CGFloat
    @"nativeBounds" :
        [NSString stringWithFormat:@"%ldx%ld", (long)model.nativeWidth,
                                   (long)model.nativeHeight]
  };

  [self applyFieldUpdates:updates];
  [self.tableView reloadData];
}

- (void)applyQuickSelectedVersion:(ECSystemVersion *)version {
  // Calculate kernel version from iOS version
  NSInteger majorVersion =
      [[version.osVersion
           componentsSeparatedByString:@"."].firstObject integerValue];
  NSString *darwinVersion = [NSString
      stringWithFormat:@"Darwin Kernel Version %ld.0.0: %@",
                       (long)(majorVersion +
                              6), // iOS 15 = Darwin 21, iOS 18 = Darwin 24
                       [[NSDate date] description]];

  // FIXED: Key mappings matched with ECDeviceInfoManager (systemVersion,
  // systemBuildVersion)
  NSDictionary *updates = @{
    @"systemVersion" : version.osVersion,
    @"systemBuildVersion" : version.buildVersion,
    @"kernelVersion" : darwinVersion,
    @"systemName" : @"iOS"
  };

  [self applyFieldUpdates:updates];
  [self.tableView reloadData];
}

- (void)applyQuickSelectedCarrier:(ECCarrierInfo *)carrier {
  // FIXED: Added networkType update to 5G
  NSDictionary *updates = @{
    @"carrierName" : carrier.carrierName,
    @"mobileCountryCode" : carrier.mcc,
    @"mobileNetworkCode" : carrier.mnc,
    @"carrierCountry" : carrier.isoCountryCode,
    @"networkType" : @"5G" // Default to 5G (NrNSA)
  };

  [self applyFieldUpdates:updates];
  [self.tableView reloadData];
}

- (void)applyFieldUpdates:(NSDictionary *)updates {
  for (NSInteger section = 0; section < ECDeviceInfoSectionCount; section++) {
    NSArray *items =
        [self.manager itemsForSection:(ECDeviceInfoSection)section];
    for (NSInteger row = 0; row < items.count; row++) {
      ECDeviceInfoItem *item = items[row];
      NSString *newValue = updates[item.key];
      if (newValue) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row
                                                    inSection:section];
        [self updateItem:item withValue:newValue atIndexPath:indexPath];
      }
    }
  }
}

- (void)setupToolbar {
  // 使用 toolbar 代替 footerView 确保按钮始终可见
  UIToolbar *toolbar = [[UIToolbar alloc]
      initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 80)];
  toolbar.barStyle = UIBarStyleBlack;
  toolbar.translucent = NO;
  toolbar.barTintColor = [UIColor colorWithWhite:0.1 alpha:1.0];

  // 保存按钮
  _saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
  _saveButton.frame = CGRectMake(0, 0, 80, 44);
  _saveButton.backgroundColor = [UIColor systemBlueColor];
  _saveButton.layer.cornerRadius = 10;
  [_saveButton setTitle:@"💾 保存" forState:UIControlStateNormal];
  [_saveButton setTitleColor:[UIColor whiteColor]
                    forState:UIControlStateNormal];
  _saveButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
  [_saveButton addTarget:self
                  action:@selector(saveButtonPressed)
        forControlEvents:UIControlEventTouchUpInside];

  // FairPlay 探测按钮
  UIButton *fairplayButton = [UIButton buttonWithType:UIButtonTypeSystem];
  fairplayButton.frame = CGRectMake(0, 0, 80, 44);
  fairplayButton.backgroundColor = [UIColor systemPurpleColor];
  fairplayButton.layer.cornerRadius = 10;
  [fairplayButton setTitle:@"🔍 FP" forState:UIControlStateNormal];
  [fairplayButton setTitleColor:[UIColor whiteColor]
                       forState:UIControlStateNormal];
  fairplayButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
  [fairplayButton addTarget:self
                     action:@selector(fairplayButtonPressed)
           forControlEvents:UIControlEventTouchUpInside];

  // 还原按钮
  _resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
  _resetButton.frame = CGRectMake(0, 0, 80, 44);
  _resetButton.backgroundColor = [UIColor systemOrangeColor];
  _resetButton.layer.cornerRadius = 10;
  [_resetButton setTitle:@"🔄 还原" forState:UIControlStateNormal];
  [_resetButton setTitleColor:[UIColor whiteColor]
                     forState:UIControlStateNormal];
  _resetButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
  [_resetButton addTarget:self
                   action:@selector(resetButtonPressed)
         forControlEvents:UIControlEventTouchUpInside];

  // 读取原始信息按钮 (读取 Hook 前的真实设备信息)
  UIButton *readOriginalButton = [UIButton buttonWithType:UIButtonTypeSystem];
  readOriginalButton.frame = CGRectMake(0, 0, 80, 44);
  readOriginalButton.backgroundColor = [UIColor systemTealColor];
  readOriginalButton.layer.cornerRadius = 10;
  [readOriginalButton setTitle:@"📖 读取" forState:UIControlStateNormal];
  [readOriginalButton setTitleColor:[UIColor whiteColor]
                           forState:UIControlStateNormal];
  readOriginalButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
  [readOriginalButton addTarget:self
                         action:@selector(readOriginalInfoPressed)
               forControlEvents:UIControlEventTouchUpInside];

  // [HIDDEN] 读取和 FP 按钮已隐藏 (用户请求 2026-02-09)
  // UIBarButtonItem *readItem =
  //     [[UIBarButtonItem alloc] initWithCustomView:readOriginalButton];
  UIBarButtonItem *saveItem =
      [[UIBarButtonItem alloc] initWithCustomView:_saveButton];
  // UIBarButtonItem *fairplayItem =
  //     [[UIBarButtonItem alloc] initWithCustomView:fairplayButton];
  UIBarButtonItem *flexSpace = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                           target:nil
                           action:nil];
  UIBarButtonItem *resetItem =
      [[UIBarButtonItem alloc] initWithCustomView:_resetButton];

  toolbar.items = @[ flexSpace, saveItem, flexSpace, resetItem, flexSpace ];

  // 设置为导航控制器的 toolbarItems
  self.toolbarItems = toolbar.items;
  self.navigationController.toolbar.barStyle = UIBarStyleBlack;
  self.navigationController.toolbar.barTintColor = [UIColor colorWithWhite:0.1
                                                                     alpha:1.0];
  self.navigationController.toolbarHidden = NO;
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  self.navigationController.toolbarHidden = NO;
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  // 切换到其他 tab 时隐藏 toolbar
  self.navigationController.toolbarHidden = YES;
}

- (void)refreshData {
  [self.manager refreshDeviceInfo];
  [self.tableView reloadData];
  [self.refreshControl endRefreshing];
}

- (void)showInfo {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"设备信息伪装"
                       message:
                           @"此功能允许您修改设备返回给应用的信息。\n\n• "
                           @"红色值 = 已修改\n• 灰色值 = "
                           @"原始值\n\n点击任意行可编辑值，修改后记得点击保存修"
                           @"改。\n\n注意：实际生效需要 Hook 注入到目标应用。"
                preferredStyle:UIAlertControllerStyleAlert];

  [alert addAction:[UIAlertAction actionWithTitle:@"知道了"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];

  [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Button Actions

- (void)saveButtonPressed {
  BOOL success;
  NSString *path;

  if (self.targetConfigPath) {
    success = [self.manager saveConfigToPath:self.targetConfigPath];
    path = self.targetConfigPath;

    // 同步到 App 容器 (User Install Support) - 使用 root helper
    if (success && self.targetContainerPath) {
      extern NSString *rootHelperPath(void);
      extern int spawnRoot(NSString * path, NSArray * args, NSString * *stdOut,
                           NSString * *stdErr);

      // 确保目标目录存在
      NSString *containerDir =
          [self.targetContainerPath stringByDeletingLastPathComponent];
      spawnRoot(rootHelperPath(), @[ @"mkdir", @"-p", containerDir ], nil, nil);

      // 使用 root helper 复制
      int ret = spawnRoot(
          rootHelperPath(),
          @[ @"copy-file", self.targetConfigPath, self.targetContainerPath ],
          nil, nil);
      if (ret != 0) {
        NSLog(@"[ECDeviceInfo] Warning: Failed to sync to container (ret=%d)",
              ret);
      } else {
        NSLog(@"[ECDeviceInfo] Synced config to container: %@",
              self.targetContainerPath);
      }
    }
  } else {
    success = [self.manager saveChanges];
    path = [self.manager configFilePath];
  }

  // 如果有 completionBlock（从注入安装流程调用），保存后关闭并继续安装
  if (self.completionBlock && success) {
    __weak typeof(self) weakSelf = self;
    [self dismissViewControllerAnimated:YES
                             completion:^{
                               if (weakSelf.completionBlock) {
                                 weakSelf.completionBlock();
                               }
                             }];
    return;
  }

  // 普通保存流程，显示提示
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:success ? @"✅ 保存成功" : @"❌ 保存失败"
                       message:success
                                   ? [NSString
                                         stringWithFormat:@"配置已保存到:\n%@",
                                                          path]
                                   : @"无法保存配置文件"
                preferredStyle:UIAlertControllerStyleAlert];

  [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];

  [self presentViewController:alert animated:YES completion:nil];
}

- (void)cancelButtonPressed {
  __weak typeof(self) weakSelf = self;
  [self dismissViewControllerAnimated:YES
                           completion:^{
                             if (weakSelf.cancelBlock) {
                               weakSelf.cancelBlock();
                             }
                           }];
}

- (void)resetButtonPressed {
  UIAlertController *confirm = [UIAlertController
      alertControllerWithTitle:@"⚠️ 确认还原"
                       message:@"确定要将所有设备信息还原为真实值吗？\n\n此操作"
                               @"不可撤销。"
                preferredStyle:UIAlertControllerStyleAlert];

  [confirm addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

  [confirm
      addAction:
          [UIAlertAction
              actionWithTitle:@"还原"
                        style:UIAlertActionStyleDestructive
                      handler:^(UIAlertAction *action) {
                        [self.manager resetToDefaults];
                        // 如果有目标路径，也要清除目标文件（或恢复默认）
                        if (self.targetConfigPath) {
                          // 重新保存一份空配置（即默认值）到目标路径，或者删除文件
                          [self.manager saveConfigToPath:self.targetConfigPath];
                        }
                        [self.tableView reloadData];

                        UIAlertController *done = [UIAlertController
                            alertControllerWithTitle:@"✅ 已还原"
                                             message:
                                                 @"所有设备信息已还原为真实值"
                                      preferredStyle:
                                          UIAlertControllerStyleAlert];
                        [done addAction:
                                  [UIAlertAction
                                      actionWithTitle:@"确定"
                                                style:UIAlertActionStyleDefault
                                              handler:nil]];
                        [self presentViewController:done
                                           animated:YES
                                         completion:nil];
                      }]];

  [self presentViewController:confirm animated:YES completion:nil];
}

// 读取原始（未 Hook）的设备信息
- (void)readOriginalInfoPressed {
  UIAlertController *confirm = [UIAlertController
      alertControllerWithTitle:@"📖 读取原始信息"
                       message:@"此功能将读取设备的\"真实\"信息（绕过 "
                               @"Hook），用于确保保存的"
                               @"配置是正确的原始值。\n\n注意：这会覆盖当前显示"
                               @"的所有值。"
                preferredStyle:UIAlertControllerStyleAlert];

  [confirm addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

  [confirm
      addAction:
          [UIAlertAction
              actionWithTitle:@"读取"
                        style:UIAlertActionStyleDefault
                      handler:^(UIAlertAction *action) {
                        // 调用 Manager 的刷新方法（它内部读取真实系统 API 值）
                        [self.manager refreshDeviceInfo];
                        [self.tableView reloadData];

                        UIAlertController *done = [UIAlertController
                            alertControllerWithTitle:@"✅ 已读取"
                                             message:@"已读取设备原始信息并刷新"
                                                     @"界面。\n\n"
                                                     @"现在可以点击\"保存\"将这"
                                                     @"些值写入配置文件。"
                                      preferredStyle:
                                          UIAlertControllerStyleAlert];
                        [done addAction:
                                  [UIAlertAction
                                      actionWithTitle:@"确定"
                                                style:UIAlertActionStyleDefault
                                              handler:nil]];
                        [self presentViewController:done
                                           animated:YES
                                         completion:nil];
                      }]];

  [self presentViewController:confirm animated:YES completion:nil];
}

- (void)refreshAppsButtonPressed {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:@"正在刷新"
                                          message:@"正在刷新应用注册..."
                                   preferredStyle:UIAlertControllerStyleAlert];
  [self presentViewController:alert animated:YES completion:nil];

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSString *helperPath = rootHelperPath();
    if (helperPath) {
      // 使用 refresh-safe：只增量补注册已知带标记应用为 System 类型，保护 LSD 不彻底清库
      // refresh-all 会执行 _LSPrivateRebuildApplicationDatabasesForSystemApps 导致 ECMAIN 丢失
      // refresh-safe 自带干掉 backboardd 使得缓存重载，应用立即可用
      spawnRoot(helperPath, @[ @"refresh-safe" ], nil, nil);
    } else {
      NSLog(@"[ECDeviceInfo] RootHelper path is nil!");
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      [alert
          dismissViewControllerAnimated:YES
                             completion:^{
                               UIAlertController *done = [UIAlertController
                                   alertControllerWithTitle:@"✅ 刷新完成"
                                                    message:
                                                        @"已将所有 TrollStore 管理的应用重新注册为 "
                                                        @"System 类型。\n\n现在可以正常打开，重启后也不会消失。"
                                             preferredStyle:
                                                 UIAlertControllerStyleAlert];
                               [done
                                   addAction:
                                       [UIAlertAction
                                           actionWithTitle:@"确定"
                                                     style:
                                                         UIAlertActionStyleDefault
                                                   handler:nil]];
                               [self presentViewController:done
                                                  animated:YES
                                                completion:nil];
                             }];
    });
  });
}

#pragma mark - FairPlay Detection

- (void)fairplayButtonPressed {
  [self scanFairPlayFiles];
}

- (void)scanFairPlayFiles {
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableString *report = [NSMutableString stringWithString:@""];
        NSFileManager *fm = [NSFileManager defaultManager];

        // FairPlay 相关目录列表
        NSArray *pathsToCheck = @[
          @"/var/mobile/Library/FairPlay", @"/var/root/Library/FairPlay",
          @"/var/mobile/Library/iTunes", @"/var/root/Library/iTunes",
          @"/var/mobile/Library/Caches/com.apple.itunesstored",
          @"/var/mobile/Library/Preferences/com.apple.itunesstored.plist",
          @"/var/mobile/Documents", @"/var/containers/Bundle/Application"
        ];

        [report appendString:@"=== FairPlay 文件扫描报告 ===\n\n"];

        for (NSString *path in pathsToCheck) {
          BOOL isDir = NO;
          BOOL exists = [fm fileExistsAtPath:path isDirectory:&isDir];

          if (exists) {
            if (isDir) {
              NSError *error = nil;
              NSArray *contents = [fm contentsOfDirectoryAtPath:path
                                                          error:&error];
              if (contents) {
                [report appendFormat:@"📁 %@\n", path];
                [report appendFormat:@"   子项: %lu 个\n",
                                     (unsigned long)contents.count];

                // 列出前 20 个项目
                NSInteger limit = MIN(20, contents.count);
                for (NSInteger i = 0; i < limit; i++) {
                  NSString *item = contents[i];
                  NSString *fullPath =
                      [path stringByAppendingPathComponent:item];
                  BOOL itemIsDir = NO;
                  [fm fileExistsAtPath:fullPath isDirectory:&itemIsDir];

                  // 获取文件大小
                  NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath
                                                             error:nil];
                  unsigned long long size = [attrs fileSize];

                  [report appendFormat:@"   %@ %@ (%llu bytes)\n",
                                       itemIsDir ? @"📁" : @"📄", item, size];
                }
                if (contents.count > 20) {
                  [report appendFormat:@"   ... 还有 %lu 个项目\n",
                                       (unsigned long)(contents.count - 20)];
                }
              } else {
                [report appendFormat:@"⚠️ %@ (无法读取: %@)\n", path,
                                     error.localizedDescription];
              }
            } else {
              // 是文件
              NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
              unsigned long long size = [attrs fileSize];
              [report appendFormat:@"📄 %@ (%llu bytes)\n", path, size];
            }
          } else {
            [report appendFormat:@"❌ %@ (不存在)\n", path];
          }
          [report appendString:@"\n"];
        }

        // 扫描已安装应用的 SC_Info 目录
        [report appendString:@"=== 已安装应用 SC_Info 扫描 ===\n\n"];
        NSString *bundlePath = @"/var/containers/Bundle/Application";
        if ([fm fileExistsAtPath:bundlePath]) {
          NSArray *apps = [fm contentsOfDirectoryAtPath:bundlePath error:nil];
          NSInteger foundCount = 0;

          for (NSString *appUUID in apps) {
            NSString *appPath =
                [bundlePath stringByAppendingPathComponent:appUUID];
            NSArray *appContents = [fm contentsOfDirectoryAtPath:appPath
                                                           error:nil];

            for (NSString *item in appContents) {
              if ([item hasSuffix:@".app"]) {
                NSString *scInfoPath =
                    [[appPath stringByAppendingPathComponent:item]
                        stringByAppendingPathComponent:@"SC_Info"];

                if ([fm fileExistsAtPath:scInfoPath]) {
                  foundCount++;
                  NSArray *scContents = [fm contentsOfDirectoryAtPath:scInfoPath
                                                                error:nil];
                  [report appendFormat:@"📱 %@\n", item];
                  [report appendFormat:@"   SC_Info: %lu 个文件\n",
                                       (unsigned long)scContents.count];

                  for (NSString *scFile in scContents) {
                    NSString *scFilePath =
                        [scInfoPath stringByAppendingPathComponent:scFile];
                    NSDictionary *attrs = [fm attributesOfItemAtPath:scFilePath
                                                               error:nil];
                    unsigned long long size = [attrs fileSize];
                    [report
                        appendFormat:@"   - %@ (%llu bytes)\n", scFile, size];
                  }
                  [report appendString:@"\n"];

                  if (foundCount >= 10) {
                    [report appendString:@"   ... 更多应用省略\n\n"];
                    break;
                  }
                }
              }
            }
            if (foundCount >= 10)
              break;
          }

          if (foundCount == 0) {
            [report appendString:@"未找到任何带有 SC_Info 的应用\n"];
          }
        }

        // 尝试查找 fairplayd 进程
        [report appendString:@"=== FairPlay 系统组件 ===\n\n"];
        [report appendString:
                    @"fairplayd 守护进程: 需要检查 /usr/libexec/fairplayd\n"];
        [report appendString:@"FairplayIOKit: 内核模块\n"];

        dispatch_async(dispatch_get_main_queue(), ^{
          [self showFairPlayReport:report];
        });
      });
}

- (void)showFairPlayReport:(NSString *)report {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"🔍 FairPlay 扫描结果"
                       message:@"扫描完成，点击复制查看完整报告"
                preferredStyle:UIAlertControllerStyleAlert];

  [alert addAction:
             [UIAlertAction
                 actionWithTitle:@"复制报告"
                           style:UIAlertActionStyleDefault
                         handler:^(UIAlertAction *action) {
                           [UIPasteboard generalPasteboard].string = report;

                           UIAlertController *done = [UIAlertController
                               alertControllerWithTitle:@"✅ 已复制"
                                                message:@"报告已复制到剪贴板，"
                                                        @"可粘贴到其他应用查看"
                                         preferredStyle:
                                             UIAlertControllerStyleAlert];
                           [done
                               addAction:
                                   [UIAlertAction
                                       actionWithTitle:@"确定"
                                                 style:UIAlertActionStyleDefault
                                               handler:nil]];
                           [self presentViewController:done
                                              animated:YES
                                            completion:nil];
                         }]];

  [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return ECDeviceInfoSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  return [self.manager itemsForSection:(ECDeviceInfoSection)section].count;
}

- (nullable NSString *)tableView:(UITableView *)tableView
         titleForHeaderInSection:(NSInteger)section {
  return [self.manager titleForSection:(ECDeviceInfoSection)section];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *CellIdentifier = @"DeviceInfoCell";

  UITableViewCell *cell =
      [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                  reuseIdentifier:CellIdentifier];
    cell.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    // 选中背景色
    UIView *selectedBg = [[UIView alloc] init];
    selectedBg.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    cell.selectedBackgroundView = selectedBg;
  }

  NSArray *items =
      [self.manager itemsForSection:(ECDeviceInfoSection)indexPath.section];
  ECDeviceInfoItem *item = items[indexPath.row];

  cell.textLabel.text = item.displayName;

  // 网络拦截 section 中的开关项使用 UISwitch
  BOOL isSwitch = ([item.key isEqualToString:@"enableNetworkInterception"] ||
                   [item.key isEqualToString:@"disableQUIC"]);
  if (isSwitch) {
    cell.detailTextLabel.text = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;

    UISwitch *sw = nil;
    if ([cell.accessoryView isKindOfClass:[UISwitch class]]) {
      sw = (UISwitch *)cell.accessoryView;
    } else {
      sw = [[UISwitch alloc] init];
      sw.onTintColor = [UIColor systemGreenColor];
      [sw addTarget:self
                    action:@selector(switchToggled:)
          forControlEvents:UIControlEventValueChanged];
      cell.accessoryView = sw;
    }
    sw.on = [item.currentValue isEqualToString:@"YES"];
    sw.tag = indexPath.section * 1000 + indexPath.row;
  } else {
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.detailTextLabel.text = item.currentValue;

    // 如果已修改，显示红色！
    if (item.isModified) {
      cell.detailTextLabel.textColor = [UIColor systemRedColor];
    } else {
      cell.detailTextLabel.textColor = [UIColor lightGrayColor];
    }
  }

  return cell;
}

// Hook 开关切换回调
- (void)switchToggled:(UISwitch *)sender {
  NSInteger section = sender.tag / 1000;
  NSInteger row = sender.tag % 1000;
  NSArray *items = [self.manager itemsForSection:(ECDeviceInfoSection)section];
  if (row < (NSInteger)items.count) {
    ECDeviceInfoItem *item = items[row];
    item.currentValue = sender.isOn ? @"YES" : @"NO";
  }
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];

  // 开关项不弹编辑框（已用 UISwitch 处理）
  NSArray *checkItems =
      [self.manager itemsForSection:(ECDeviceInfoSection)indexPath.section];
  ECDeviceInfoItem *checkItem = checkItems[indexPath.row];
  if ([checkItem.key isEqualToString:@"enableNetworkInterception"] ||
      [checkItem.key isEqualToString:@"disableQUIC"]) {
    return;
  }

  NSArray *items =
      [self.manager itemsForSection:(ECDeviceInfoSection)indexPath.section];
  ECDeviceInfoItem *item = items[indexPath.row];

  // Specific handling for Country Code -> Smart Selection
  if ([item.key isEqualToString:@"countryCode"]) {
    ECCountrySelectionViewController *vc =
        [[ECCountrySelectionViewController alloc] init];
    UINavigationController *nav =
        [[UINavigationController alloc] initWithRootViewController:vc];

    // 使用 weakSelf 避免循环引用
    __weak typeof(self) weakSelf = self;
    vc.selectionBlock = ^(ECRegionInfo *info) {
      // 1. Update Country & Auto-Apply Presets (Language, Timezone, Currency)
      // 使用 Manager 的预设逻辑，确保语言格式正确 (例如巴西 -> pt-BR)
      [weakSelf.manager applyCountryPreset:info.countryCode];

      // 2. Reload UI to reflect changes
      [weakSelf.tableView reloadData];
    };

    [self presentViewController:nav animated:YES completion:nil];
    return;
  }

  // Specific handling for Timezone -> Global Selection
  if ([item.key isEqualToString:@"timezone"]) {
    ECTimeZoneSelectionViewController *vc =
        [[ECTimeZoneSelectionViewController alloc] init];

    __weak typeof(self) weakSelf = self;
    vc.selectionBlock = ^(NSString *selectedTimeZone) {
      // Update the item value
      ECDeviceInfoItem *currentItem =
          [weakSelf.manager getAllItems][@"timezone"];
      if (currentItem) {
        currentItem.currentValue = selectedTimeZone;
        currentItem.isModified = ![currentItem.currentValue
            isEqualToString:currentItem.originalValue];
        [weakSelf.tableView reloadData];
      }
    };

    [self.navigationController pushViewController:vc animated:YES];
    return;
  }

  // Define selectable fields and their options for others
  NSDictionary *optionsMap = @{
    // "countryCode" and "timezone" removed from here as they are handled above
    @"languageCode" :
        @[ @"zh-Hans", @"en", @"ja", @"ko", @"zh-Hant", @"de", @"fr", @"es" ],
    @"localeIdentifier" : @[
      @"zh_CN", @"en_US", @"en_CN", @"ja_JP", @"ko_KR", @"zh_HK", @"zh_TW",
      @"en_GB"
    ],
    @"currencyCode" :
        @[ @"CNY", @"USD", @"JPY", @"EUR", @"GBP", @"HKD", @"KRW" ]
  };

  NSArray *options = optionsMap[item.key];
  if (options) {
    [self showSelectionSheetForItem:item options:options atIndexPath:indexPath];
  } else {
    // For other items, show default edit alert
    [self showEditAlertForItem:item atIndexPath:indexPath];
  }
}

- (void)autoFillRegionInfo:(ECRegionInfo *)info {
  // 构建正确的语言标识符
  // 如果 languageCode 已经包含区域标识（如 zh-Hans,
  // zh-Hant），不要再附加国家代码
  // 否则，附加国家代码形成完整的语言-地区标识符（如 pt-BR, en-US）
  NSString *langWithRegion;
  if ([info.languageCode containsString:@"-"]) {
    // 已经是完整格式（如 zh-Hans, zh-Hant-HK）
    langWithRegion = info.languageCode;
  } else {
    // 需要附加国家代码（如 pt -> pt-BR, en -> en-US）
    langWithRegion = [NSString
        stringWithFormat:@"%@-%@", info.languageCode, info.countryCode];
  }

  // 1. 更新区域伪装字段
  NSArray *regionItems =
      [self.manager itemsForSection:ECDeviceInfoSectionRegion];
  for (ECDeviceInfoItem *subItem in regionItems) {
    NSIndexPath *path =
        [NSIndexPath indexPathForRow:[regionItems indexOfObject:subItem]
                           inSection:ECDeviceInfoSectionRegion];
    if ([subItem.key isEqualToString:@"localeIdentifier"]) {
      [self updateItem:subItem
             withValue:info.localeIdentifier
           atIndexPath:path];
    } else if ([subItem.key isEqualToString:@"currencyCode"]) {
      [self updateItem:subItem withValue:info.currencyCode atIndexPath:path];
    } else if ([subItem.key isEqualToString:@"timezone"]) {
      [self updateItem:subItem withValue:info.timezone atIndexPath:path];
    } else if ([subItem.key isEqualToString:@"storeRegion"]) {
      [self updateItem:subItem withValue:info.countryCode atIndexPath:path];
    } else if ([subItem.key isEqualToString:@"priorityRegion"]) {
      [self updateItem:subItem withValue:info.countryCode atIndexPath:path];
    }
  }

  // 1b. 更新语言伪装字段
  NSArray *langItems =
      [self.manager itemsForSection:ECDeviceInfoSectionLanguage];
  for (ECDeviceInfoItem *subItem in langItems) {
    NSIndexPath *path =
        [NSIndexPath indexPathForRow:[langItems indexOfObject:subItem]
                           inSection:ECDeviceInfoSectionLanguage];
    if ([subItem.key isEqualToString:@"languageCode"]) {
      [self updateItem:subItem withValue:langWithRegion atIndexPath:path];
    } else if ([subItem.key isEqualToString:@"preferredLanguage"]) {
      [self updateItem:subItem withValue:langWithRegion atIndexPath:path];
    } else if ([subItem.key isEqualToString:@"systemLanguage"]) {
      [self updateItem:subItem withValue:langWithRegion atIndexPath:path];
    } else if ([subItem.key isEqualToString:@"btdCurrentLanguage"]) {
      [self updateItem:subItem withValue:langWithRegion atIndexPath:path];
    }
  }

  // 2. 更新国家/地区代码 (顶部单独 section)
  NSArray *countryItems =
      [self.manager itemsForSection:ECDeviceInfoSectionCountry];
  for (ECDeviceInfoItem *subItem in countryItems) {
    NSIndexPath *path =
        [NSIndexPath indexPathForRow:[countryItems indexOfObject:subItem]
                           inSection:ECDeviceInfoSectionCountry];
    if ([subItem.key isEqualToString:@"countryCode"]) {
      [self updateItem:subItem withValue:info.countryCode atIndexPath:path];
    }
  }

  // 3. 更新运营商伪装字段
  NSArray *carrierItems =
      [self.manager itemsForSection:ECDeviceInfoSectionCarrier];
  for (ECDeviceInfoItem *subItem in carrierItems) {
    NSIndexPath *path =
        [NSIndexPath indexPathForRow:[carrierItems indexOfObject:subItem]
                           inSection:ECDeviceInfoSectionCarrier];
    if ([subItem.key isEqualToString:@"carrierCountry"]) {
      [self updateItem:subItem withValue:info.countryCode atIndexPath:path];
    }
  }

  [self.tableView reloadData];
}

- (void)showSelectionSheetForItem:(ECDeviceInfoItem *)item
                          options:(NSArray *)options
                      atIndexPath:(NSIndexPath *)indexPath {
  UIAlertController *sheet = [UIAlertController
      alertControllerWithTitle:[NSString stringWithFormat:@"选择: %@",
                                                          item.displayName]
                       message:nil
                preferredStyle:UIAlertControllerStyleActionSheet];

  // Add option actions
  for (NSString *opt in options) {
    [sheet addAction:[UIAlertAction
                         actionWithTitle:opt
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *_Nonnull action) {
                                   [self updateItem:item
                                          withValue:opt
                                        atIndexPath:indexPath];
                                 }]];
  }

  // Custom Input
  [sheet addAction:[UIAlertAction
                       actionWithTitle:@"自定义输入..."
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self showEditAlertForItem:item
                                                atIndexPath:indexPath];
                               }]];

  // Cancel
  [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  // iPad Popover support
  if (sheet.popoverPresentationController) {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell;
    sheet.popoverPresentationController.sourceRect = cell.bounds;
  }

  [self presentViewController:sheet animated:YES completion:nil];
}

- (void)updateItem:(ECDeviceInfoItem *)item
         withValue:(NSString *)newValue
       atIndexPath:(NSIndexPath *)indexPath {
  if (newValue.length > 0) {
    item.currentValue = newValue;
    item.isModified = ![newValue isEqualToString:item.originalValue];
    [self.tableView reloadRowsAtIndexPaths:@[ indexPath ]
                          withRowAnimation:UITableViewRowAnimationFade];
  }
}

- (void)showEditAlertForItem:(ECDeviceInfoItem *)item
                 atIndexPath:(NSIndexPath *)indexPath {
  NSString *message =
      [NSString stringWithFormat:@"原始值: %@", item.originalValue];

  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:[NSString stringWithFormat:@"修改: %@",
                                                          item.displayName]
                       message:message
                preferredStyle:UIAlertControllerStyleAlert];

  [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
    textField.text = item.currentValue;
    textField.placeholder = item.originalValue;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
  }];

  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  [alert addAction:[UIAlertAction
                       actionWithTitle:@"确定"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {
                                 NSString *newValue =
                                     alert.textFields.firstObject.text;
                                 if (newValue.length > 0) {
                                   item.currentValue = newValue;
                                   item.isModified = ![newValue
                                       isEqualToString:item.originalValue];
                                   [self.tableView
                                       reloadRowsAtIndexPaths:@[ indexPath ]
                                             withRowAnimation:
                                                 UITableViewRowAnimationFade];
                                 }
                               }]];

  [alert addAction:[UIAlertAction
                       actionWithTitle:@"恢复原值"
                                 style:UIAlertActionStyleDestructive
                               handler:^(UIAlertAction *action) {
                                 item.currentValue = item.originalValue;
                                 item.isModified = NO;
                                 [self.tableView
                                     reloadRowsAtIndexPaths:@[ indexPath ]
                                           withRowAnimation:
                                               UITableViewRowAnimationFade];
                               }]];

  [self presentViewController:alert animated:YES completion:nil];
}

- (nullable UIView *)tableView:(UITableView *)tableView
        viewForHeaderInSection:(NSInteger)section {
  UIView *headerView = [[UIView alloc] init];
  headerView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];

  UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, 350, 24)];
  label.text = [self.manager titleForSection:(ECDeviceInfoSection)section];
  label.font = [UIFont boldSystemFontOfSize:14];
  label.textColor = [UIColor systemBlueColor];
  [headerView addSubview:label];

  return headerView;
}

- (CGFloat)tableView:(UITableView *)tableView
    heightForHeaderInSection:(NSInteger)section {
  return 40;
}

- (CGFloat)tableView:(UITableView *)tableView
    heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  return 54;
}

@end

NS_ASSUME_NONNULL_END
