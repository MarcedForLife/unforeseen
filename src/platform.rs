//! DLL entry point and hook thread spawning.

#[cfg(windows)]
mod windows {
    use ::windows::Win32::Foundation::{CloseHandle, BOOL, HMODULE, TRUE};
    use ::windows::Win32::System::LibraryLoader::DisableThreadLibraryCalls;
    use ::windows::Win32::System::Threading::{CreateThread, THREAD_CREATION_FLAGS};
    use std::ffi::c_void;

    const DLL_PROCESS_ATTACH: u32 = 1;

    unsafe extern "system" fn hook_thread(_param: *mut c_void) -> u32 {
        crate::run();
        0
    }

    #[no_mangle]
    pub unsafe extern "system" fn DllMain(
        module: HMODULE,
        reason: u32,
        _reserved: *mut c_void,
    ) -> BOOL {
        if reason == DLL_PROCESS_ATTACH {
            let _ = DisableThreadLibraryCalls(module);
            if let Ok(handle) = CreateThread(
                None,
                0,
                Some(hook_thread),
                None,
                THREAD_CREATION_FLAGS(0),
                None,
            ) {
                let _ = CloseHandle(handle);
            }
        }
        TRUE
    }
}

#[cfg(unix)]
mod linux {
    #[used]
    #[link_section = ".init_array"]
    static CONSTRUCTOR: unsafe extern "C" fn() = on_load;

    unsafe extern "C" fn on_load() {
        std::thread::spawn(crate::run);
    }
}
