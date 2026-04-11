//! Signature scanner for the commentary achievement guard in server.dll.
//!
//! Locates the commentary check helper via the `"Achievements disabled"` debug
//! string, then resolves the `E8` call target to find the function entry point.

use crate::pe;

/// Locate the entry point of the server-side commentary check function.
///
/// The server has a helper that returns false when commentary mode is active,
/// called from three places in the achievement pipeline. Instead of patching
/// each caller, we return the function's entry so the caller can stub it to
/// always return true.
///
/// # Safety
/// `server_base` must point to the base of a fully-loaded server module.
pub unsafe fn find_server_commentary_check(server_base: *const u8) -> Option<*mut u8> {
    let sections = pe::sections(server_base);
    let rdata = sections.iter().find(|sec| sec.is_readonly_data())?;
    let text = sections.iter().find(|sec| sec.is_executable())?;

    let rdata_slice = section_slice(server_base, rdata);
    let text_slice = section_slice(server_base, text);
    let text_base = server_base.add(text.virtual_address as usize);

    server_scan(server_base, rdata, rdata_slice, text_slice, text_base)
}

/// Server-side (32-bit): anchor on `push "Achievements disabled"`, find the
/// `E8` call to the commentary check just before it, and resolve the target.
unsafe fn server_scan(
    server_base: *const u8,
    rdata: &pe::Section,
    rdata_slice: &[u8],
    text_slice: &[u8],
    text_base: *const u8,
) -> Option<*mut u8> {
    let str_offset = find_bytes(rdata_slice, b"Achievements disabled")?;
    let str_va =
        (server_base.add(rdata.virtual_address as usize + str_offset) as u32).to_le_bytes();

    // Find `push <str_va>` in .text (68 XX XX XX XX)
    let push_instr: [u8; 5] = [
        0x68, str_va[0], str_va[1], str_va[2], str_va[3],
    ];
    let push_offset = find_bytes(text_slice, &push_instr)?;

    // Scan backward for `E8 ?? ?? ?? ?? 84 C0 75` (call check; test al,al; jnz).
    // The last such pattern before the push is the commentary check call.
    let search_start = push_offset.saturating_sub(64);
    let window = &text_slice[search_start..push_offset];
    let test_jnz: &[u8] = &[0x84, 0xC0, 0x75];

    let mut last_call_target = None;
    let mut pos = 0;
    while let Some(offset) = find_bytes(&window[pos..], test_jnz) {
        let abs = search_start + pos + offset;
        // The E8 call should end right at the test instruction (5 bytes before)
        if abs >= 5 && text_slice[abs - 5] == 0xE8 {
            let disp = i32::from_le_bytes(
                text_slice[abs - 4..abs].try_into().unwrap(),
            );
            // call target = next_instr_rva + disp, but we want a pointer
            let next_instr_offset = abs; // offset in text_slice
            let target_offset = (next_instr_offset as i64 + disp as i64) as usize;
            last_call_target = Some(target_offset);
        }
        pos += offset + 1;
    }

    last_call_target.map(|offset| text_base.add(offset) as *mut u8)
}

/// View a PE section as a byte slice.
unsafe fn section_slice(base: *const u8, section: &pe::Section) -> &[u8] {
    let ptr = base.add(section.virtual_address as usize);
    std::slice::from_raw_parts(ptr, section.virtual_size as usize)
}

/// Find the first occurrence of `needle` in `haystack`.
fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}
