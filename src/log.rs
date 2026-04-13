//! Diagnostic logging to a temp file and the Source engine console.

use std::io::Write;

/// Write a timestamped status line to `%TEMP%/unforeseen.log`.
pub fn file(msg: &str) {
    let path = std::env::temp_dir().join("unforeseen.log");
    let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    else {
        return;
    };
    let ts = local_time();
    let _ = writeln!(file, "[{ts}] {msg}");
}

/// Print to the Source engine console via tier0's `Msg` export.
#[cfg(windows)]
pub fn console(msg: &str) {
    use std::ffi::c_char;
    use windows::core::PCSTR;
    use windows::Win32::System::LibraryLoader::{GetModuleHandleA, GetProcAddress};

    type MsgFn = unsafe extern "C" fn(*const c_char);

    let Ok(tier0) = (unsafe { GetModuleHandleA(PCSTR::from_raw(c"tier0.dll".as_ptr() as _)) })
    else {
        return;
    };
    let Some(addr) = (unsafe { GetProcAddress(tier0, PCSTR::from_raw(c"Msg".as_ptr() as _)) })
    else {
        return;
    };
    let msg_fn: MsgFn = unsafe { std::mem::transmute(addr) };
    if let Ok(c_msg) = std::ffi::CString::new(msg) {
        unsafe { msg_fn(c_msg.as_ptr()) };
    }
}

#[cfg(unix)]
pub fn console(msg: &str) {
    eprint!("{msg}");
}

#[cfg(windows)]
fn local_time() -> String {
    #[repr(C)]
    struct SystemTime {
        _year: u16,
        _month: u16,
        _day_of_week: u16,
        _day: u16,
        hour: u16,
        minute: u16,
        second: u16,
        _ms: u16,
    }
    extern "system" {
        fn GetLocalTime(time: *mut SystemTime);
    }
    let mut time = unsafe { std::mem::zeroed::<SystemTime>() };
    unsafe { GetLocalTime(&mut time) };
    format!("{:02}:{:02}:{:02}", time.hour, time.minute, time.second)
}

#[cfg(unix)]
fn local_time() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};

    let epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as libc::time_t;
    let mut tm = unsafe { std::mem::zeroed::<libc::tm>() };
    unsafe { libc::localtime_r(&epoch, &mut tm) };
    format!("{:02}:{:02}:{:02}", tm.tm_hour, tm.tm_min, tm.tm_sec)
}
