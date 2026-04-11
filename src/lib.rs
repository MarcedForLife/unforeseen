//! Unforeseen Achievements: patches the commentary achievement guard in Source
//! engine games so achievements unlock during commentary playthroughs.

mod log;
mod module;
mod patcher;
mod pe;
mod platform;
mod scanner;
mod version_proxy;

fn run() {
    if let Err(msg) = run_inner() {
        log::file(&format!("FAILED: {msg}"));
    }
}

fn run_inner() -> Result<(), String> {
    log::file("--- session start ---");
    log::file("waiting for server module...");

    let server_base =
        module::wait_for_server().ok_or("server module not found after timeout")?;
    log::file(&format!("found server module at {server_base:p}"));

    let func = unsafe { scanner::find_server_commentary_check(server_base) }
        .ok_or("could not locate commentary check (pattern may need updating)")?;

    let offset = func as usize - server_base as usize;
    log::file(&format!("commentary check at server+0x{offset:X}"));

    unsafe { patcher::stub_return_true(func) }?;

    log::file("commentary check stubbed");
    log::console("Unforeseen Achievements: achievements now unlock in commentary mode\n");
    Ok(())
}
