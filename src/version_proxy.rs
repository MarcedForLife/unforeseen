//! version.dll proxy exports for auto-loading.
//!
//! When the hook DLL is placed in the game directory as `version.dll`, Windows
//! loads it instead of the system copy. These forwarding stubs lazy-load the
//! real `version.dll` from System32 on first call and delegate every export.
#[cfg(windows)]
mod inner {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use windows::core::PCSTR;
    use windows::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryA};

    static REAL_MODULE: AtomicUsize = AtomicUsize::new(0);

    fn real_module() -> usize {
        let cached = REAL_MODULE.load(Ordering::Relaxed);
        if cached != 0 {
            return cached;
        }
        let handle = unsafe {
            LoadLibraryA(PCSTR::from_raw(
                c"C:\\Windows\\System32\\version.dll".as_ptr() as _,
            ))
        }
        .expect("failed to load real version.dll from System32");
        let addr = handle.0 as usize;
        REAL_MODULE.store(addr, Ordering::Relaxed);
        addr
    }

    unsafe fn get_fn(name: &std::ffi::CStr) -> usize {
        let module = windows::Win32::Foundation::HMODULE(real_module() as _);
        GetProcAddress(module, PCSTR::from_raw(name.as_ptr() as _))
            .expect("failed to resolve version.dll export") as usize
    }

    macro_rules! proxy {
        ($export_name:ident, $c_name:expr) => {
            #[no_mangle]
            pub unsafe extern "system" fn $export_name(
                a: usize,
                b: usize,
                c: usize,
                d: usize,
                e: usize,
                f: usize,
            ) -> usize {
                static FN: AtomicUsize = AtomicUsize::new(0);
                let mut addr = FN.load(Ordering::Relaxed);
                if addr == 0 {
                    addr = get_fn($c_name);
                    FN.store(addr, Ordering::Relaxed);
                }
                let func: unsafe extern "system" fn(
                    usize,
                    usize,
                    usize,
                    usize,
                    usize,
                    usize,
                ) -> usize = std::mem::transmute(addr);
                func(a, b, c, d, e, f)
            }
        };
    }

    proxy!(GetFileVersionInfoA, c"GetFileVersionInfoA");
    proxy!(GetFileVersionInfoByHandle, c"GetFileVersionInfoByHandle");
    proxy!(GetFileVersionInfoExA, c"GetFileVersionInfoExA");
    proxy!(GetFileVersionInfoExW, c"GetFileVersionInfoExW");
    proxy!(GetFileVersionInfoSizeA, c"GetFileVersionInfoSizeA");
    proxy!(GetFileVersionInfoSizeExA, c"GetFileVersionInfoSizeExA");
    proxy!(GetFileVersionInfoSizeExW, c"GetFileVersionInfoSizeExW");
    proxy!(GetFileVersionInfoSizeW, c"GetFileVersionInfoSizeW");
    proxy!(GetFileVersionInfoW, c"GetFileVersionInfoW");
    proxy!(VerFindFileA, c"VerFindFileA");
    proxy!(VerFindFileW, c"VerFindFileW");
    proxy!(VerInstallFileA, c"VerInstallFileA");
    proxy!(VerInstallFileW, c"VerInstallFileW");
    proxy!(VerLanguageNameA, c"VerLanguageNameA");
    proxy!(VerLanguageNameW, c"VerLanguageNameW");
    proxy!(VerQueryValueA, c"VerQueryValueA");
    proxy!(VerQueryValueW, c"VerQueryValueW");
}
