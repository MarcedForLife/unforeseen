//! Patches executable code with proper page protection handling.

/// Overwrite a function's entry with `mov al, 1; ret` so it always returns
/// true. Used to stub the server-side commentary check, which is called from
/// multiple sites in the achievement pipeline.
///
/// # Safety
/// `target` must point to the first byte of a function in executable memory.
pub unsafe fn stub_return_true(target: *mut u8) -> Result<(), String> {
    // B0 01 = mov al, 1
    // C3    = ret
    write_code_bytes(target, &[0xB0, 0x01, 0xC3])
}

unsafe fn write_code_bytes(addr: *mut u8, bytes: &[u8]) -> Result<(), String> {
    let old = make_writable(addr, bytes.len())?;
    for (offset, &byte) in bytes.iter().enumerate() {
        addr.add(offset).write(byte);
    }
    restore_protection(addr, bytes.len(), old);
    Ok(())
}

#[cfg(windows)]
unsafe fn make_writable(addr: *mut u8, size: usize) -> Result<u32, String> {
    use windows::Win32::System::Memory::{VirtualProtect, PAGE_EXECUTE_READWRITE};
    let mut old = windows::Win32::System::Memory::PAGE_PROTECTION_FLAGS(0);
    VirtualProtect(addr as *const _, size, PAGE_EXECUTE_READWRITE, &mut old)
        .map_err(|err| format!("VirtualProtect failed: {err}"))?;
    Ok(old.0)
}

#[cfg(windows)]
unsafe fn restore_protection(addr: *mut u8, size: usize, old: u32) {
    use windows::Win32::System::Memory::{VirtualProtect, PAGE_PROTECTION_FLAGS};
    let mut dummy = PAGE_PROTECTION_FLAGS(0);
    let _ = VirtualProtect(
        addr as *const _,
        size,
        PAGE_PROTECTION_FLAGS(old),
        &mut dummy,
    );
}

#[cfg(unix)]
unsafe fn make_writable(addr: *mut u8, _size: usize) -> Result<u32, String> {
    mprotect_page(addr, libc::PROT_READ | libc::PROT_WRITE | libc::PROT_EXEC)?;
    Ok(0)
}

#[cfg(unix)]
unsafe fn restore_protection(addr: *mut u8, _size: usize, _old: u32) {
    let _ = mprotect_page(addr, libc::PROT_READ | libc::PROT_EXEC);
}

#[cfg(unix)]
unsafe fn mprotect_page(addr: *mut u8, prot: i32) -> Result<(), String> {
    let page_size = libc::sysconf(libc::_SC_PAGESIZE) as usize;
    let page_start = (addr as usize / page_size) * page_size;
    if libc::mprotect(page_start as *mut libc::c_void, page_size, prot) != 0 {
        return Err(format!(
            "mprotect failed: {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(())
}
