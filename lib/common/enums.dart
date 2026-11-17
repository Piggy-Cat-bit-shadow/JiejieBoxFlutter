// UI-only enums. The FlClash originals live in lib/enum/enum.dart, which also
// carries the Mihomo domain (rule actions, clash modes, proxy types). Only the
// view/layout ones are vendored here; adding a domain enum is A2's decision.

enum ViewMode { mobile, laptop, desktop }

enum ProxiesLayout { loose, standard, tight }

enum ProxyCardType { loose, standard, compact }

enum PageLabel { dashboard, proxies, profiles, tools }

enum NavigationItemMode { mobile, desktop, more, moreFull }
