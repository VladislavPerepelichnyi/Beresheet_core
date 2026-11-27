// =============================================================================
// Restores `default_nettype wire after the sdspi sources.
//
// The upstream sdspi files set `default_nettype none and do not reset it.
// Compiler directives are not scoped to a file, so in a single-pass tool flow
// (Gowin synthesis) the setting leaks into every later source, including
// vendor wrappers that rely on implicit net types. Listing this file directly
// after the sdspi sources contains it without modifying upstream code.
// =============================================================================
`default_nettype wire
