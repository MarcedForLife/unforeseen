//! Locates game modules in the running process.

/// Poll for up to 60 seconds until the server module is loaded.
pub fn wait_for_server() -> Option<*const u8> {
    for _ in 0..600 {
        if let Some(base) = find_module(c"server.dll") {
            return Some(base);
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    None
}

#[cfg(windows)]
fn find_module(name: &std::ffi::CStr) -> Option<*const u8> {
    use windows::core::PCSTR;
    use windows::Win32::System::LibraryLoader::GetModuleHandleA;

    let handle = unsafe { GetModuleHandleA(PCSTR::from_raw(name.as_ptr() as _)) }.ok()?;
    Some(handle.0 as *const u8)
}

#[cfg(unix)]
fn find_module(name: &std::ffi::CStr) -> Option<*const u8> {
    let needle = name.to_str().ok()?.replace(".dll", ".so");
    let maps = std::fs::read_to_string("/proc/self/maps").ok()?;
    for line in maps.lines() {
        if !line.contains(&needle) {
            continue;
        }
        let start_hex = line.split_whitespace().next()?.split('-').next()?;
        let base = usize::from_str_radix(start_hex, 16).ok()?;
        return Some(base as *const u8);
    }
    None
}
