#import "ECFileBrowserViewController.h"
#import "ECFileViewerViewController.h"
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ECRegionInfo : NSObject
@property(nonatomic, copy) NSString *countryCode;
@property(nonatomic, copy) NSString *displayName; // English + Chinese
@property(nonatomic, copy) NSString *languageCode;
@property(nonatomic, copy) NSString *localeIdentifier;
@property(nonatomic, copy) NSString *currencyCode;
@property(nonatomic, copy) NSString *timezone;
@end

typedef void (^ECRegionSelectionBlock)(ECRegionInfo *info);

@interface ECCountrySelectionViewController : UITableViewController

@property(nonatomic, copy) ECRegionSelectionBlock selectionBlock;

@end

NS_ASSUME_NONNULL_END

@implementation ECRegionInfo
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
  add(@"SH", @"圣赫勒拿", @"Saint Helena", @"en", @"SHP",
      @"Atlantic/St_Helena");
  add(@"KN", @"圣基茨和尼维斯", @"Saint Kitts and Nevis", @"en", @"XCD",
      @"America/St_Kitts");
  add(@"LC", @"圣卢西亚", @"Saint Lucia", @"en", @"XCD", @"America/St_Lucia");
  add(@"PM", @"圣皮埃尔和密克隆", @"Saint Pierre and Miquelon", @"fr", @"EUR",
      @"America/Miquelon");
  add(@"VC", @"圣文森特和格林纳丁斯", @"Saint Vincent and the Grenadines",
      @"en", @"XCD", @"America/St_Vincent");
  add(@"WS", @"萨摩亚", @"Samoa", @"sm", @"WST", @"Pacific/Apia");
  add(@"SM", @"圣马力诺", @"San Marino", @"it", @"EUR", @"Europe/San_Marino");
  add(@"ST", @"圣多美和普林西比", @"Sao Tome and Principe", @"pt", @"STN",
      @"Africa/Sao_Tome");
  add(@"SA", @"沙特阿拉伯", @"Saudi Arabia", @"ar", @"SAR", @"Asia/Riyadh");
  add(@"SN", @"塞内加尔", @"Senegal", @"fr", @"XOF", @"Africa/Dakar");
  add(@"RS", @"塞尔维亚", @"Serbia", @"sr", @"RSD", @"Europe/Belgrade");
  add(@"SC", @"塞舌尔", @"Seychelles", @"en", @"SCR", @"Indian/Mahe");
  add(@"SL", @"塞拉利昂", @"Sierra Leone", @"en", @"SLL", @"Africa/Freetown");
  add(@"SG", @"新加坡", @"Singapore", @"en", @"SGD", @"Asia/Singapore");
  add(@"SK", @"斯洛伐克", @"Slovakia", @"sk", @"EUR", @"Europe/Bratislava");
  add(@"SI", @"斯洛文尼亚", @"Slovenia", @"sl", @"EUR", @"Europe/Ljubljana");
  add(@"SB", @"所罗门群岛", @"Solomon Islands", @"en", @"SBD",
      @"Pacific/Guadalcanal");
  add(@"SO", @"索马里", @"Somalia", @"so", @"SOS", @"Africa/Mogadishu");
  add(@"ZA", @"南非", @"South Africa", @"en", @"ZAR", @"Africa/Johannesburg");
  add(@"ES", @"西班牙", @"Spain", @"es", @"EUR", @"Europe/Madrid");
  add(@"LK", @"斯里兰卡", @"Sri Lanka", @"si", @"LKR", @"Asia/Colombo");
  add(@"SD", @"苏丹", @"Sudan", @"ar", @"SDG", @"Africa/Khartoum");
  add(@"SR", @"苏里南", @"Suriname", @"nl", @"SRD", @"America/Paramaribo");
  add(@"SJ", @"斯瓦尔巴和扬马延", @"Svalbard and Jan Mayen", @"no", @"NOK",
      @"Arctic/Longyearbyen");
  add(@"SZ", @"斯威士兰", @"Swaziland", @"en", @"SZL", @"Africa/Mbabane");
  add(@"SE", @"瑞典", @"Sweden", @"sv", @"SEK", @"Europe/Stockholm");
  add(@"CH", @"瑞士", @"Switzerland", @"de", @"CHF", @"Europe/Zurich");
  add(@"SY", @"叙利亚", @"Syrian Arab Republic", @"ar", @"SYP",
      @"Asia/Damascus");
  add(@"TW", @"中国台湾", @"Taiwan", @"zh-Hant", @"TWD", @"Asia/Taipei");
  add(@"TJ", @"塔吉克斯坦", @"Tajikistan", @"tg", @"TJS", @"Asia/Dushanbe");
  add(@"TZ", @"坦桑尼亚", @"Tanzania, United Republic of", @"sw", @"TZS",
      @"Africa/Dar_es_Salaam");
  add(@"TH", @"泰国", @"Thailand", @"th", @"THB", @"Asia/Bangkok");
  add(@"TL", @"东帝汶", @"Timor-Leste", @"pt", @"USD", @"Asia/Dili");
  add(@"TG", @"多哥", @"Togo", @"fr", @"XOF", @"Africa/Lome");
  add(@"TK", @"托克劳", @"Tokelau", @"en", @"NZD", @"Pacific/Fakaofo");
  add(@"TO", @"汤加", @"Tonga", @"to", @"TOP", @"Pacific/Tongatapu");
  add(@"TT", @"特立尼达和多巴哥", @"Trinidad and Tobago", @"en", @"TTD",
      @"America/Port_of_Spain");
  add(@"TN", @"突尼斯", @"Tunisia", @"ar", @"TND", @"Africa/Tunis");
  add(@"TR", @"土耳其", @"Turkey", @"tr", @"TRY", @"Europe/Istanbul");
  add(@"TM", @"土库曼斯坦", @"Turkmenistan", @"tk", @"TMT", @"Asia/Ashgabat");
  add(@"TC", @"特克斯和凯科斯群岛", @"Turks and Caicos Islands", @"en", @"USD",
      @"America/Grand_Turk");
  add(@"TV", @"图瓦卢", @"Tuvalu", @"en", @"AUD", @"Pacific/Funafuti");
  add(@"UG", @"乌干达", @"乌干达", @"Uganda", @"en", @"UGX", @"Africa/Kampala");
  add(@"UA", @"乌克兰", @"Ukraine", @"uk", @"UAH", @"Europe/Kiev");
  add(@"AE", @"阿联酋", @"United Arab Emirates", @"ar", @"AED", @"Asia/Dubai");
  add(@"GB", @"英国", @"United Kingdom", @"en", @"GBP", @"Europe/London");
  add(@"US", @"美国", @"United States", @"en", @"USD", @"America/New_York");
  add(@"UY", @"乌拉圭", @"Uruguay", @"es", @"UYU", @"America/Montevideo");
  add(@"UZ", @"乌兹别克斯坦", @"Uzbekistan", @"uz", @"UZS", @"Asia/Tashkent");
  add(@"VU", @"瓦努阿图", @"Vanuatu", @"en", @"VUV", @"Pacific/Efate");
  add(@"VE", @"委内瑞拉", @"Venezuela", @"es", @"VES", @"America/Caracas");
  add(@"VN", @"越南", @"Vietnam", @"vi", @"VND", @"Asia/Ho_Chi_Minh");
  add(@"VG", @"英属维尔京群岛", @"Virgin Islands, British", @"en", @"USD",
      @"America/Tortola");
  add(@"VI", @"美属维尔京群岛", @"Virgin Islands, U.S.", @"en", @"USD",
      @"America/St_Thomas");
  add(@"WF", @"瓦利斯和富图纳", @"Wallis and Futuna", @"fr", @"XPF",
      @"Pacific/Wallis");
  add(@"EH", @"西撒哈拉", @"Western Sahara", @"ar", @"MAD", @"Africa/El_Aaiun");
  add(@"YE", @"也门", @"Yemen", @"ar", @"YER", @"Asia/Aden");
  add(@"ZM", @"赞比亚", @"Zambia", @"en", @"ZMW", @"Africa/Lusaka");
  add(@"ZW", @"津巴布韦", @"Zimbabwe", @"en", @"ZWL", @"Africa/Harare");

  self.allRegions = [arr sortedArrayUsingComparator:^NSComparisonResult(
                             ECRegionInfo *obj1, ECRegionInfo *obj2) {
    return [obj1.countryCode compare:obj2.countryCode];
  }];
  self.filteredRegions = self.allRegions;
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 1;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  return self.filteredRegions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *cellId = @"RegionCell";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                  reuseIdentifier:cellId];
  }

  ECRegionInfo *info = self.filteredRegions[indexPath.row];
  cell.textLabel.text = info.displayName;
  cell.detailTextLabel.text = [NSString
      stringWithFormat:@"%@ / %@ / %@ / %@", info.countryCode,
                       info.languageCode, info.currencyCode, info.timezone];

  return cell;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
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
    self.filteredRegions = [self.allRegions
        filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(
                                                     ECRegionInfo *info,
                                                     NSDictionary *bindings) {
          return ([info.displayName rangeOfString:text
                                          options:NSCaseInsensitiveSearch]
                          .location != NSNotFound ||
                  [info.countryCode rangeOfString:text
                                          options:NSCaseInsensitiveSearch]
                          .location != NSNotFound);
        }]];
  }
  [self.tableView reloadData];
}

@end

// ==========================================
// ECFileViewerViewController Implementation
// ==========================================

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
    // 查看模式：右边显示 [编辑]
    // 暂时移除分享按钮，确保编辑按钮显示
    UIBarButtonItem *editItem =
        [[UIBarButtonItem alloc] initWithTitle:@"编辑"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(editTapped)];

    self.navigationItem.rightBarButtonItem = editItem;
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

  // 写入文件
  [contentToSave writeToFile:self.filePath
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:&error];

  if (error) {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"保存失败"
                         message:error.localizedDescription
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
  } else {
    self.originalContent = self.textView.text;
    self.isEditing = NO;
    self.textView.editable = NO;
    [self.textView resignFirstResponder];
    [self setupNavigationItems];
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

// ==========================================
// ECFileBrowserViewController Implementation
// ==========================================

@interface ECFileBrowserViewController ()
@property(nonatomic, strong) NSString *currentPath;
@property(nonatomic, strong) NSArray *files;
@end

@implementation ECFileBrowserViewController

- (instancetype)initWithPath:(NSString *)path {
  if (self = [super initWithStyle:UITableViewStylePlain]) {
    _currentPath = path;
    self.title = [path lastPathComponent];
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  [self loadFiles];
}

- (void)loadFiles {
  NSError *error = nil;
  NSArray *contents =
      [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.currentPath
                                                          error:&error];

  if (error) {
    // Show empty or error state
    self.files = @[];
    NSLog(@"Error reading directory: %@", error);
  } else {
    // Sort: Folders first, then files
    self.files = [contents sortedArrayUsingComparator:^NSComparisonResult(
                               NSString *obj1, NSString *obj2) {
      NSString *path1 = [self.currentPath stringByAppendingPathComponent:obj1];
      NSString *path2 = [self.currentPath stringByAppendingPathComponent:obj2];

      BOOL isDir1 = NO, isDir2 = NO;
      [[NSFileManager defaultManager] fileExistsAtPath:path1
                                           isDirectory:&isDir1];
      [[NSFileManager defaultManager] fileExistsAtPath:path2
                                           isDirectory:&isDir2];

      if (isDir1 && !isDir2)
        return NSOrderedAscending;
      if (!isDir1 && isDir2)
        return NSOrderedDescending;

      return [obj1 compare:obj2 options:NSCaseInsensitiveSearch];
    }];
  }
  [self.tableView reloadData];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 1;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  return self.files.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *CellIdentifier = @"FileCell";
  UITableViewCell *cell =
      [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                  reuseIdentifier:CellIdentifier];
  }

  NSString *fileName = self.files[indexPath.row];
  NSString *fullPath =
      [self.currentPath stringByAppendingPathComponent:fileName];

  BOOL isDir = NO;
  [[NSFileManager defaultManager] fileExistsAtPath:fullPath isDirectory:&isDir];

  cell.textLabel.text = fileName;
  if (isDir) {
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.detailTextLabel.text = @"目录";
    cell.imageView.image = [UIImage systemImageNamed:@"folder"];
  } else {
    cell.accessoryType = UITableViewCellAccessoryNone;
    NSDictionary *attrs =
        [[NSFileManager defaultManager] attributesOfItemAtPath:fullPath
                                                         error:nil];
    uint64_t fileSize = [attrs fileSize];
    cell.detailTextLabel.text = [NSByteCountFormatter
        stringFromByteCount:fileSize
                 countStyle:NSByteCountFormatterCountStyleFile];
    cell.imageView.image = [UIImage systemImageNamed:@"doc.text"];
  }

  return cell;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];

  NSString *fileName = self.files[indexPath.row];
  NSString *fullPath =
      [self.currentPath stringByAppendingPathComponent:fileName];

  BOOL isDir = NO;
  [[NSFileManager defaultManager] fileExistsAtPath:fullPath isDirectory:&isDir];

  if (isDir) {
    ECFileBrowserViewController *nextVC =
        [[ECFileBrowserViewController alloc] initWithPath:fullPath];
    [self.navigationController pushViewController:nextVC animated:YES];
  } else {
    ECFileViewerViewController *viewer =
        [[ECFileViewerViewController alloc] initWithPath:fullPath];
    [self.navigationController pushViewController:viewer animated:YES];
  }
}

@end
