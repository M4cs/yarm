// Distributed Darwin notification used to tell already-injected dylibs in
// running processes to re-read the config and re-apply the radius without
// requiring an app relaunch.
//
// The dylib subscribes to `com.maxbridgland.yarm.reload`; this posts to it.

use anyhow::Result;
use core_foundation::base::TCFType;
use core_foundation::string::CFString;
use core_foundation_sys::base::CFTypeRef;
use core_foundation_sys::string::CFStringRef;

#[repr(C)]
struct __CFNotificationCenter([u8; 0]);
type CFNotificationCenterRef = *const __CFNotificationCenter;

extern "C" {
    fn CFNotificationCenterGetDistributedCenter() -> CFNotificationCenterRef;
    fn CFNotificationCenterPostNotification(
        center: CFNotificationCenterRef,
        name: CFStringRef,
        object: CFTypeRef,
        userInfo: CFTypeRef,
        deliverImmediately: bool,
    );
}

pub fn post_reload() -> Result<()> {
    let name = CFString::new("com.maxbridgland.yarm.reload");
    unsafe {
        let center = CFNotificationCenterGetDistributedCenter();
        CFNotificationCenterPostNotification(
            center,
            name.as_concrete_TypeRef(),
            std::ptr::null(),
            std::ptr::null(),
            true,
        );
    }
    Ok(())
}
