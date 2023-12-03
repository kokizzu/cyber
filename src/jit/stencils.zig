pub const addFloat = [_]u8{ 0x40, 0x00, 0x67, 0x9e, 0x61, 0x00, 0x67, 0x9e, 0x00, 0x28, 0x61, 0x1e, 0x02, 0x00, 0x66, 0x9e };
pub const subFloat = [_]u8{ 0x40, 0x00, 0x67, 0x9e, 0x61, 0x00, 0x67, 0x9e, 0x00, 0x38, 0x61, 0x1e, 0x02, 0x00, 0x66, 0x9e };
pub const mulFloat = [_]u8{ 0x40, 0x00, 0x67, 0x9e, 0x61, 0x00, 0x67, 0x9e, 0x00, 0x08, 0x61, 0x1e, 0x02, 0x00, 0x66, 0x9e };
pub const divFloat = [_]u8{ 0x40, 0x00, 0x67, 0x9e, 0x61, 0x00, 0x67, 0x9e, 0x00, 0x18, 0x61, 0x1e, 0x02, 0x00, 0x66, 0x9e };
pub const addInt = [_]u8{ 0x68, 0x00, 0x02, 0x8b, 0xc2, 0xff, 0xef, 0xd2, 0x02, 0xbd, 0x40, 0xb3 };
pub const subInt = [_]u8{ 0x48, 0x00, 0x03, 0xcb, 0xc2, 0xff, 0xef, 0xd2, 0x02, 0xbd, 0x40, 0xb3 };
pub const mulInt = [_]u8{ 0x68, 0x7c, 0x02, 0x9b, 0xc2, 0xff, 0xef, 0xd2, 0x02, 0xbd, 0x40, 0xb3 };
pub const divInt = [_]u8{ 0x7f, 0xbc, 0x40, 0xf2, 0xe0, 0x00, 0x00, 0x54, 0x68, 0xbc, 0x40, 0x93, 0x49, 0xbc, 0x40, 0x93, 0x28, 0x0d, 0xc8, 0x9a, 0xc2, 0xff, 0xef, 0xd2, 0x02, 0xbd, 0x40, 0xb3, 0x00, 0x00, 0x00, 0x14 };
pub const lessInt = [_]u8{ 0x48, 0xbc, 0x40, 0x93, 0x69, 0xbc, 0x70, 0xd3, 0x2a, 0x00, 0xc0, 0xd2, 0x8a, 0xff, 0xef, 0xf2, 0x4b, 0x01, 0x40, 0xb2, 0x1f, 0x41, 0x89, 0xeb, 0x62, 0xb1, 0x8a, 0x9a };
pub const intPair = [_]u8{ 0x42, 0xbc, 0x40, 0x93, 0x63, 0xbc, 0x40, 0x93 };
pub const isTrue = [_]u8{ 0x48, 0x7c, 0x60, 0x92, 0x08, 0xc9, 0x50, 0x92, 0x29, 0x00, 0xc0, 0xd2, 0x89, 0xff, 0xef, 0xf2, 0x2a, 0x01, 0x40, 0xb2, 0x5f, 0x00, 0x0a, 0xeb, 0xea, 0x17, 0x9f, 0x1a, 0x8b, 0xff, 0xef, 0xd2, 0x5f, 0x00, 0x0b, 0xeb, 0xeb, 0x07, 0x9f, 0x1a, 0x1f, 0x01, 0x09, 0xeb, 0x42, 0x01, 0x8b, 0x1a };
pub const lessIntCFlag = [_]u8{ 0x5f, 0x00, 0x03, 0xeb, 0x4a, 0x00, 0x00, 0x54, 0x00, 0x00, 0x00, 0x14, 0xc0, 0x03, 0x5f, 0xd6 };
pub const call = [_]u8{ 0x21, 0xa0, 0x00, 0x91 };
pub const callHost = [_]u8{ 0xf8, 0x5f, 0xbc, 0xa9, 0xf6, 0x57, 0x01, 0xa9, 0xf4, 0x4f, 0x02, 0xa9, 0xfd, 0x7b, 0x03, 0xa9, 0xfd, 0xc3, 0x00, 0x91, 0xf3, 0x03, 0x03, 0xaa, 0xf4, 0x03, 0x02, 0xaa, 0xf5, 0x03, 0x01, 0xaa, 0xf6, 0x03, 0x00, 0xaa, 0xf7, 0xff, 0x9f, 0xd2, 0x57, 0x00, 0xc0, 0xf2, 0x97, 0xff, 0xef, 0xf2, 0x01, 0x10, 0x00, 0xf9, 0x62, 0x1e, 0x00, 0x12, 0xe1, 0x03, 0x14, 0xaa, 0x00, 0x00, 0x00, 0x94, 0x1f, 0x00, 0x17, 0xeb, 0xa1, 0x01, 0x00, 0x54, 0xe0, 0x03, 0x16, 0xaa, 0xe1, 0x03, 0x15, 0xaa, 0xe2, 0x03, 0x14, 0xaa, 0xe3, 0x03, 0x13, 0xaa, 0xe4, 0xff, 0x9f, 0xd2, 0x44, 0x00, 0xc0, 0xf2, 0x84, 0xff, 0xef, 0xf2, 0xfd, 0x7b, 0x43, 0xa9, 0xf4, 0x4f, 0x42, 0xa9, 0xf6, 0x57, 0x41, 0xa9, 0xf8, 0x5f, 0xc4, 0xa8, 0x00, 0x00, 0x00, 0x14, 0xe4, 0x03, 0x00, 0xaa, 0xe0, 0x03, 0x16, 0xaa, 0xe1, 0x03, 0x15, 0xaa, 0xe2, 0x03, 0x14, 0xaa, 0xe3, 0x03, 0x13, 0xaa, 0xfd, 0x7b, 0x43, 0xa9, 0xf4, 0x4f, 0x42, 0xa9, 0xf6, 0x57, 0x41, 0xa9, 0xf8, 0x5f, 0xc4, 0xa8 };
pub const end = [_]u8{ 0x48, 0x1c, 0x40, 0x92, 0x08, 0xd8, 0x01, 0xf9 };
pub const stringTemplate = [_]u8{ 0xf6, 0x57, 0xbd, 0xa9, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91, 0xf3, 0x03, 0x03, 0xaa, 0xf4, 0x03, 0x02, 0xaa, 0xf5, 0x03, 0x01, 0xaa, 0xf6, 0x03, 0x00, 0xaa, 0x88, 0x04, 0x00, 0x11, 0x84, 0x1c, 0x00, 0x12, 0x02, 0x1d, 0x00, 0x12, 0xe1, 0x03, 0x14, 0xaa, 0x00, 0x00, 0x00, 0x94, 0x24, 0x7c, 0x40, 0xf2, 0x20, 0x01, 0x00, 0x54, 0xe0, 0x03, 0x16, 0xaa, 0xe1, 0x03, 0x15, 0xaa, 0xe2, 0x03, 0x14, 0xaa, 0xe3, 0x03, 0x13, 0xaa, 0xfd, 0x7b, 0x42, 0xa9, 0xf4, 0x4f, 0x41, 0xa9, 0xf6, 0x57, 0xc3, 0xa8, 0x00, 0x00, 0x00, 0x14, 0xe5, 0x03, 0x00, 0xaa, 0xe0, 0x03, 0x16, 0xaa, 0xe1, 0x03, 0x15, 0xaa, 0xe2, 0x03, 0x14, 0xaa, 0xe3, 0x03, 0x13, 0xaa, 0xe4, 0x03, 0x05, 0xaa, 0xfd, 0x7b, 0x42, 0xa9, 0xf4, 0x4f, 0x41, 0xa9, 0xf6, 0x57, 0xc3, 0xa8 };
pub const dumpJitSection = [_]u8{ 0xf8, 0x5f, 0xbc, 0xa9, 0xf6, 0x57, 0x01, 0xa9, 0xf4, 0x4f, 0x02, 0xa9, 0xfd, 0x7b, 0x03, 0xa9, 0xfd, 0xc3, 0x00, 0x91, 0xf3, 0x03, 0x05, 0xaa, 0xf4, 0x03, 0x04, 0xaa, 0xf5, 0x03, 0x03, 0xaa, 0xf6, 0x03, 0x02, 0xaa, 0xf7, 0x03, 0x01, 0xaa, 0xf8, 0x03, 0x00, 0xaa, 0x00, 0x00, 0x00, 0x94, 0xe0, 0x03, 0x18, 0xaa, 0xe1, 0x03, 0x17, 0xaa, 0xe2, 0x03, 0x16, 0xaa, 0xe3, 0x03, 0x15, 0xaa, 0xe4, 0x03, 0x14, 0xaa, 0xe5, 0x03, 0x13, 0xaa, 0xfd, 0x7b, 0x43, 0xa9, 0xf4, 0x4f, 0x42, 0xa9, 0xf6, 0x57, 0x41, 0xa9, 0xf8, 0x5f, 0xc4, 0xa8 };
pub const release = [_]u8{ 0xf6, 0x57, 0xbd, 0xa9, 0xf4, 0x4f, 0x01, 0xa9, 0xfd, 0x7b, 0x02, 0xa9, 0xfd, 0x83, 0x00, 0x91, 0xf3, 0x03, 0x02, 0xaa, 0xf4, 0x03, 0x01, 0xaa, 0xf5, 0x03, 0x00, 0xaa, 0x88, 0xff, 0xff, 0xd2, 0x5f, 0x00, 0x08, 0xeb, 0x03, 0x01, 0x00, 0x54, 0x61, 0xc2, 0x40, 0x92, 0x28, 0x04, 0x40, 0xb9, 0x08, 0x05, 0x00, 0x71, 0x28, 0x04, 0x00, 0xb9, 0x61, 0x00, 0x00, 0x54, 0xe0, 0x03, 0x15, 0xaa, 0x00, 0x00, 0x00, 0x94, 0xe0, 0x03, 0x15, 0xaa, 0xe1, 0x03, 0x14, 0xaa, 0xe2, 0x03, 0x13, 0xaa, 0xfd, 0x7b, 0x42, 0xa9, 0xf4, 0x4f, 0x41, 0xa9, 0xf6, 0x57, 0xc3, 0xa8 };
pub const release_zFreeObject = 64;
pub const dumpJitSection_zDumpJitSection = 44;
pub const stringTemplate_interrupt5 = 88;
pub const stringTemplate_zAllocStringTemplate2 = 48;
pub const callHost_interrupt5 = 116;
pub const callHost_hostFunc = 60;
pub const divInt_divByZero = 32;
