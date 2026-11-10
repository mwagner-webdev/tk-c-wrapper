#ifdef _WIN32
#   include "tkWinDefault.h"
#else
#   if defined(MAC_OSX_TK)
#	include "tkMacOSXDefault.h"
#   else
#	include "tkUnixDefault.h"
#   endif
#endif
