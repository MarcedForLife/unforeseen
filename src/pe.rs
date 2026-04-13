//! Parses PE section headers from an in-memory module image.

/// Represents one entry from the PE section table.
pub struct Section {
    pub virtual_address: u32,
    pub virtual_size: u32,
    pub characteristics: u32,
}

// IMAGE_SCN_* flags from the PE spec
const SECTION_EXECUTABLE: u32 = 0x2000_0000;
const SECTION_READABLE: u32 = 0x4000_0000;
const SECTION_WRITABLE: u32 = 0x8000_0000;

impl Section {
    pub fn is_executable(&self) -> bool {
        self.characteristics & SECTION_EXECUTABLE != 0
    }

    /// Readable but not executable — covers .rdata / .rodata.
    pub fn is_readonly_data(&self) -> bool {
        let has_read = self.characteristics & SECTION_READABLE != 0;
        let has_exec = self.characteristics & SECTION_EXECUTABLE != 0;
        let has_write = self.characteristics & SECTION_WRITABLE != 0;
        has_read && !has_exec && !has_write
    }
}

/// Parse the PE section table from a module that is already loaded in memory.
///
/// # Safety
/// `module_base` must point to the start of a valid, fully-loaded PE image.
/// The caller must ensure the image stays mapped for the lifetime of the
/// returned `Vec`.
pub unsafe fn sections(module_base: *const u8) -> Vec<Section> {
    // DOS header: e_lfanew is at offset 0x3C
    let nt_offset = (module_base.add(0x3C) as *const u32).read_unaligned() as usize;
    let nt_base = module_base.add(nt_offset);

    // FileHeader layout (same for PE32 and PE32+):
    //   +0x06  NumberOfSections       u16
    //   +0x14  SizeOfOptionalHeader   u16
    let num_sections = (nt_base.add(0x06) as *const u16).read_unaligned() as usize;
    let optional_size = (nt_base.add(0x14) as *const u16).read_unaligned() as usize;

    // Section headers immediately follow: signature(4) + file_header(20) + optional_header
    let section_table = nt_base.add(4 + 20 + optional_size);

    // Each IMAGE_SECTION_HEADER is 40 bytes:
    //   +0x08  VirtualSize        u32
    //   +0x0C  VirtualAddress     u32  (RVA)
    //   +0x24  Characteristics    u32
    (0..num_sections)
        .map(|index| {
            let header = section_table.add(index * 40);
            Section {
                virtual_size: (header.add(0x08) as *const u32).read_unaligned(),
                virtual_address: (header.add(0x0C) as *const u32).read_unaligned(),
                characteristics: (header.add(0x24) as *const u32).read_unaligned(),
            }
        })
        .collect()
}
