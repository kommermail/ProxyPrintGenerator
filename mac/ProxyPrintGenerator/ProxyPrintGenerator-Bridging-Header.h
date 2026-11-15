//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#include <TargetConditionals.h>

#if TARGET_OS_OSX
// CUPS, the Mac's printing system: the print sheet reads printers,
// their drivers and options, and sends jobs through it, the way the
// lp command does (MacPrinting.swift).
#include <cups/cups.h>
#endif
