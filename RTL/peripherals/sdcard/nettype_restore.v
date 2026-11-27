// =============================================================================
// One directive, and it exists because of a real build failure.
//
// The sdspi sources each open with `default_nettype none and never put it back.
// That is fine on its own - it is good practice inside a file - but Gowin's
// synthesiser analyses every source in one pass, and a directive is not scoped
// to a file. So the setting leaked forward into the next file added after them,
// which was gowin_rpll.v: a vendor primitive wrapper whose ports are declared
// without net types, exactly the style `default_nettype none forbids.
//
// The failure named the PLL, which had not been touched, and said nothing about
// the SD card, which had. Restoring the default right after the sdspi sources
// keeps them byte-identical to upstream and keeps the leak from travelling.
// It must stay immediately after them in build.tcl.
// =============================================================================
`default_nettype wire
