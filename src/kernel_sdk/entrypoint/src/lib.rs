// SPDX-FileCopyrightText: 2022-2023 TriliTech <contact@trili.tech>
// SPDX-FileCopyrightText: 2023 Nomadic Labs <contact@nomadic-labs.com>
//
// SPDX-License-Identifier: MIT

#![doc = include_str!("../README.md")]
#![deny(missing_docs)]
#![deny(rustdoc::broken_intra_doc_links)]
#![cfg_attr(not(feature = "std"), no_std)]

#[cfg(feature = "dlmalloc")]
mod allocator {
    use dlmalloc::GlobalDlmalloc;

    #[global_allocator]
    static ALLOCATOR: GlobalDlmalloc = GlobalDlmalloc;
}

/// Set panic hook
#[cfg(feature = "panic-hook")]
pub fn set_panic_hook() {
    std::panic::set_hook(Box::new(tezos_smart_rollup_panic_hook::panic_handler));
}

/// Dummy panic hook that does nothing.
#[cfg(not(feature = "panic-hook"))]
pub fn set_panic_hook() {}

#[cfg(feature = "alloc")]
extern crate alloc;

/// Derive `kernel_run` & `mock_kernel_run` entrypoints.
///
/// ```no_run
/// # extern crate alloc;
/// #[macro_use] extern crate tezos_smart_rollup_entrypoint;
/// #[macro_use] extern crate tezos_smart_rollup_debug;
///
/// use tezos_smart_rollup_host::runtime::Runtime;
///
/// fn run<Host: Runtime>(host: &mut Host) {
///   debug_msg!(host, "Hello: {}", "Kernel!");
/// }
///
/// # #[cfg(doc)]
/// kernel_entry!(run);
/// ```
#[macro_export]
macro_rules! kernel_entry {
    ($kernel_run: expr) => {
        /// The `kernel_run` function is called by the wasm host at regular intervals.
        #[cfg(target_arch = "wasm32")]
        #[no_mangle]
        pub extern "C" fn kernel_run() {
            $crate::set_panic_hook();
            use $crate::RollupHost;
            let mut host = unsafe { RollupHost::new() };
            $kernel_run(&mut host)
        }
    };
}

#[doc(hidden)]
pub use tezos_smart_rollup_core::rollup_host::RollupHost;
